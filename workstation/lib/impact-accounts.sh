#!/bin/bash
# =============================================================================
# impact-accounts.sh: accounts, groups, SSH public keys, and files in a
# person's home folder
#
# Purpose
#   1. Questions about accounts and groups (does it exist, which number, which
#      home folder, who is a member).
#   2. The repository folder of a person (the REPO_BASE setting with %h and %u
#      replaced).
#   3. Checking a public SSH key line and computing its fingerprint. A
#      fingerprint is a short code that identifies a key.
#   4. Reading and writing files in a person's home folder in a safe way: the
#      work is done with the rights of the person, so a prepared symbolic link
#      (a pointer to another path) can never make root write somewhere else.
#
# Who runs it
#   Nobody directly. impact-common.sh loads it.
#
# Usage (inside a command, after loading impact-common.sh)
#   if impact_account_exists alice; then home="$(impact_account_home alice)"; fi
#   impact_parse_ed25519_key "$key_text" || impact_die 2 "$IMPACT_KEY_ERROR" ""
#   impact_user_write_file alice "$home/.ssh/authorized_keys" 600 <<<"$IMPACT_KEY_LINE"
#
# What it changes on the system
#   Loading changes nothing. The functions impact_user_mkdir,
#   impact_user_write_file, impact_user_remove_file and impact_repo_base_create
#   create or change files of one person when a command calls them.
#
# How to undo
#   Nothing to undo for the file itself.
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

# Results of impact_parse_ed25519_key.
IMPACT_KEY_LINE=''       # the key in its plain form: "ssh-ed25519 <key data>"
IMPACT_KEY_BLOB=''       # the key data alone
IMPACT_KEY_COMMENT=''    # the comment of the key line, reduced to safe characters
IMPACT_KEY_FINGERPRINT=''  # SHA256:...
IMPACT_KEY_ERROR=''      # why a key text was refused

# The record of one enrolled account after impact_account_record_load.
declare -gA IMPACT_ACCOUNT_RECORD=()
IMPACT_ACCOUNT_RECORD_ERRORS=()
readonly -a IMPACT_ACCOUNT_RECORD_KEYS=(ACCOUNT_RECORD_VERSION ACCOUNT GITHUB_NAME USER_NUMBER STATE CHANGED)

# =============================================================================
# Accounts and groups
# =============================================================================

# impact__lookup_name_ok TEXT
#   Internal: is TEXT a name that may be handed to the account database at
#   all? The rule is wider than the rule for new IMPACT accounts, because
#   existing system accounts can contain upper-case letters and dots. A text
#   of digits only is refused: the tool "getent" would read it as a number
#   and return a different account.
impact__lookup_name_ok() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,63}\$?$ ]]
}

# impact_account_field ACCOUNT NUMBER
#   Prints one field of the account's entry in the account database:
#   1 name, 3 user number, 4 number of the primary group, 6 home folder,
#   7 login shell.
#   Result: failure when the account does not exist.
impact_account_field() {
    local entry
    impact__lookup_name_ok "$1" || return 1
    # getent asks the system's account database (local files and, where
    # configured, a directory service). The entry has fields separated by ":".
    entry="$(getent passwd -- "$1" 2>/dev/null)" || return 1
    [[ -n "$entry" ]] || return 1
    printf '%s\n' "$entry" | cut -d: -f"$2"
}

# impact_account_exists ACCOUNT
#   Result: success when a Linux account with this name exists.
impact_account_exists() {
    impact_account_field "$1" 1 >/dev/null
}

# impact_account_uid ACCOUNT
#   Prints the user number (UID) of the account.
impact_account_uid() {
    impact_account_field "$1" 3
}

# impact_account_gid ACCOUNT
#   Prints the number of the account's primary group.
impact_account_gid() {
    impact_account_field "$1" 4
}

# impact_account_home ACCOUNT
#   Prints the home folder of the account as the account database states it.
impact_account_home() {
    impact_account_field "$1" 6
}

# impact_account_shell ACCOUNT
#   Prints the login shell of the account.
impact_account_shell() {
    impact_account_field "$1" 7
}

# impact_account_by_uid NUMBER
#   Prints the name of the account with this user number.
#   Result: failure when no account has it.
impact_account_by_uid() {
    local entry
    [[ "$1" =~ ^[0-9]{1,10}$ ]] || return 1
    entry="$(getent passwd -- "$1" 2>/dev/null)" || return 1
    [[ -n "$entry" ]] || return 1
    printf '%s\n' "${entry%%:*}"
}

# impact_group_field GROUP NUMBER
#   Prints one field of the group's entry: 1 name, 3 group number,
#   4 the listed members separated by commas.
#   Result: failure when the group does not exist.
impact_group_field() {
    local entry
    impact__lookup_name_ok "$1" || return 1
    entry="$(getent group -- "$1" 2>/dev/null)" || return 1
    [[ -n "$entry" ]] || return 1
    printf '%s\n' "$entry" | cut -d: -f"$2"
}

# impact_group_exists GROUP
#   Result: success when a group with this name exists.
impact_group_exists() {
    impact_group_field "$1" 1 >/dev/null
}

# impact_group_gid GROUP
#   Prints the group number (GID).
impact_group_gid() {
    impact_group_field "$1" 3
}

# impact_group_by_gid NUMBER
#   Prints the name of the group with this number.
#   Result: failure when no group has it.
impact_group_by_gid() {
    local entry
    [[ "$1" =~ ^[0-9]{1,10}$ ]] || return 1
    entry="$(getent group -- "$1" 2>/dev/null)" || return 1
    [[ -n "$entry" ]] || return 1
    printf '%s\n' "${entry%%:*}"
}

# impact_group_members GROUP
#   Prints every member of the group, one name per line, sorted: the accounts
#   listed in the group's entry and the accounts that have the group as their
#   primary group.
#   Result: failure when the group does not exist.
impact_group_members() {
    local gid listed
    gid="$(impact_group_gid "$1")" || return 1
    listed="$(impact_group_field "$1" 4)" || return 1
    {
        # "tr" turns the commas into line ends.
        printf '%s\n' "$listed" | tr ',' '\n'
        # awk prints the name (field 1) of every account whose primary group
        # (field 4) is this group.
        getent passwd | awk -F: -v gid="$gid" '$4 == gid { print $1 }'
    } | sed -e '/^$/d' | sort -u
}

# impact_account_groups ACCOUNT
#   Prints the names of all groups of the account, one per line.
impact_account_groups() {
    impact_account_exists "$1" || return 1
    id -nG -- "$1" 2>/dev/null | tr ' ' '\n'
}

# impact_account_in_group ACCOUNT GROUP
#   Result: success when the account is a member of the group.
#   Example: if impact_account_in_group alice docker; then ...
impact_account_in_group() {
    local group
    while IFS= read -r group; do
        if [[ "$group" == "$2" ]]; then
            return 0
        fi
    done < <(impact_account_groups "$1")
    # "< <( ... )" feeds the output of a command into the loop while the loop
    # itself runs in the main script.
    return 1
}

# impact_name_is_free NAME
#   Result: success when NAME is used neither by an account nor by a group.
impact_name_is_free() {
    ! impact_account_exists "$1" && ! impact_group_exists "$1"
}

# impact_uid_is_free NUMBER
#   Result: success when no account has this user number.
impact_uid_is_free() {
    ! impact_account_by_uid "$1" >/dev/null
}

# impact_gid_is_free NUMBER
#   Result: success when no group has this group number.
impact_gid_is_free() {
    ! impact_group_by_gid "$1" >/dev/null
}

# impact_account_password_state ACCOUNT
#   Prints the state of the account's password: "L" locked (no password
#   login possible), "P" a usable password, "NP" no password needed.
#   Needs root rights.
impact_account_password_state() {
    local line
    impact_account_exists "$1" || return 1
    line="$(passwd -S -- "$1" 2>/dev/null)" || return 1
    # The second word of the line is the state.
    read -r _ line _ <<<"$line"
    printf '%s\n' "$line"
}

# impact_account_is_expired ACCOUNT
#   Result: success when the account has an expiry date in the past, which is
#   how impact-remove-user closes an account. Needs root rights.
impact_account_is_expired() {
    local entry expiry today
    impact_account_exists "$1" || return 1
    entry="$(getent shadow -- "$1" 2>/dev/null)" || return 1
    # Field 8 is the expiry date as a number of days since 1 January 1970.
    expiry="$(printf '%s\n' "$entry" | cut -d: -f8)"
    [[ "$expiry" =~ ^[0-9]+$ ]] || return 1
    today=$(($(date -u '+%s') / 86400))
    ((expiry <= today))
}

# =============================================================================
# The repository folder of a person
# =============================================================================

# impact_repo_base_for ACCOUNT
#   Prints the folder that holds the working copies of this person: the
#   REPO_BASE setting with %h replaced by the home folder and %u by the
#   account name. The site settings must be loaded.
#   Result: failure when the account does not exist or the result is no clean
#   absolute path.
#   Example: impact_repo_base_for alice   prints /home/alice/Repositories
impact_repo_base_for() {
    local home path
    [[ -n "${IMPACT_CONF[REPO_BASE]:-}" ]] || return 1
    home="$(impact_account_home "$1")" || return 1
    path="$(impact_expand_repo_base_template "${IMPACT_CONF[REPO_BASE]}" "$home" "$1")"
    impact_valid_abs_path "$path" || return 1
    printf '%s\n' "$path"
}

# impact_repo_base_is_ready ACCOUNT
#   Result: success when the person's repository folder exists as a real
#   folder that belongs to the person.
impact_repo_base_is_ready() {
    local path uid owner
    path="$(impact_repo_base_for "$1")" || return 1
    uid="$(impact_account_uid "$1")" || return 1
    [[ -d "$path" && ! -L "$path" ]] || return 1
    owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 1
    [[ "$owner" == "$uid" ]]
}

# impact_repo_base_create ACCOUNT
#   Creates the person's repository folder with mode 750 (the person may do
#   everything, the person's group may look, others have no access).
#   Inside the home folder the work is done as the person. Outside the home
#   folder (for example /srv/repos/%u) root creates the folder, and only when
#   the parent folder belongs to root and nobody else can write to it.
#   Needs root rights.
#   Result: failure with an error line when the folder cannot be created
#   safely.
#   Example: impact_do "Create the repository folder" impact_repo_base_create alice
impact_repo_base_create() {
    local account="$1" path home parent facts gid
    path="$(impact_repo_base_for "$account")" || {
        impact_error "The repository folder of '$account' cannot be worked out from REPO_BASE."
        return 1
    }
    home="$(impact_account_home "$account")" || return 1
    if impact_path_is_below "$path" "$home"; then
        impact_user_mkdir "$account" "$path" 750
        return
    fi
    parent="$(dirname -- "$path")"
    if [[ -L "$parent" || ! -d "$parent" ]]; then
        impact_error "The folder $parent does not exist as a real folder. Create it as root first (mode 755)."
        return 1
    fi
    facts="$(stat -c '%u %a' -- "$parent")" || return 1
    if [[ "${facts%% *}" != '0' ]] || (((8#${facts##* } & 8#022) != 0)); then
        impact_error "The folder $parent must belong to root and be writable by root only, because root creates folders in it."
        return 1
    fi
    if [[ -L "$path" ]]; then
        impact_error "$path is a symbolic link. A real folder is expected here."
        return 1
    fi
    gid="$(impact_account_gid "$account")" || return 1
    if [[ ! -e "$path" ]]; then
        mkdir -m 750 -- "$path" || return 1
        chown -- "$account:$gid" "$path" || return 1
        return 0
    fi
    impact_repo_base_is_ready "$account" || {
        impact_error "$path exists and does not belong to '$account'."
        return 1
    }
}

# =============================================================================
# The record of an enrolled account
# =============================================================================
# impact-add-user notes for every account which GitHub name belongs to it.
# The other commands read that note: the key copy in the home folder is named
# after the GitHub name, and a rebuilt workstation needs the user number.
# One file per account lies in /opt/impact/admin/accounts (root only), in the
# same KEY=value format as the settings file:
#   ACCOUNT_RECORD_VERSION=1
#   ACCOUNT=alice
#   GITHUB_NAME=alice-example        (always stored in lower case)
#   USER_NUMBER=1005
#   STATE=enrolled                   (or: removed)
#   CHANGED=2026-01-31T14:05:09Z     (time of the last change, UTC)
# A command may add lines with keys of its own; the writer keeps them.

# impact_account_record_file ACCOUNT
#   Prints the path of the record file of ACCOUNT.
#   Result: failure for a name that cannot be an account name.
impact_account_record_file() {
    impact__lookup_name_ok "$1" || return 1
    printf '%s/%s.conf\n' "$IMPACT_ACCOUNTS_DIR" "$1"
}

# impact_key_copy_path HOME_FOLDER GITHUB_NAME
#   Prints the path of the private key copy that the GUI places in a home
#   folder for git: <home>/.ssh/id_ed25519_<github name in lower case>.
#   Pure text work; nothing is looked up.
#   Example: impact_key_copy_path /home/alice Alice-Example
#            prints /home/alice/.ssh/id_ed25519_alice-example
impact_key_copy_path() {
    impact_valid_github_name "$2" || return 1
    printf '%s/.ssh/id_ed25519_%s\n' "$1" "${2,,}"
}

# impact__account_record_help KEY
#   Internal: no explanations are written into record files.
impact__account_record_help() {
    return 0
}

# impact__account_record_header
#   Internal: prints the first line of a new record file.
impact__account_record_header() {
    printf '%s\n' '# IMPACT Docker GUI: record of one enrolled account. Written by the IMPACT commands.'
}

# impact_account_record_write ACCOUNT GITHUB_NAME STATE
#   Writes or updates the record of ACCOUNT in one step (mode 600, owner
#   root). STATE is "enrolled" or "removed". The GitHub name is stored in
#   lower case, the user number is read from the account, and the time of
#   the change is set to now. Lines with other keys in an existing record
#   are kept. Needs root rights; the account must exist.
#   Result: failure with an error line for invalid input.
#   Example: impact_do "Record the GitHub name" impact_account_record_write alice alice-example enrolled
impact_account_record_write() {
    local account="$1" github_name="$2" state="$3" file uid content
    local -A values=()
    file="$(impact_account_record_file "$account")" || {
        impact_error "'$(impact_display "$account")' cannot be an account name."
        return 1
    }
    uid="$(impact_account_uid "$account")" || {
        impact_error "The account '$account' does not exist."
        return 1
    }
    if ! impact_valid_github_name "$github_name"; then
        impact_error "'$(impact_display "$github_name")' is no valid GitHub name."
        return 1
    fi
    if [[ "$state" != 'enrolled' && "$state" != 'removed' ]]; then
        impact_error "The state of an account record must be 'enrolled' or 'removed'."
        return 1
    fi
    values=(
        [ACCOUNT_RECORD_VERSION]=1 [ACCOUNT]="$account" [GITHUB_NAME]="${github_name,,}"
        [USER_NUMBER]="$uid" [STATE]="$state" [CHANGED]="$(impact_now_utc)"
    )
    if ! impact_dir_is "$IMPACT_ACCOUNTS_DIR" 700 root root; then
        impact_make_dir "$IMPACT_ACCOUNTS_DIR" 700 root root || return 1
    fi
    content="$(impact__kv_render "$file" values IMPACT_ACCOUNT_RECORD_KEYS impact__account_record_help impact__account_record_header)" || return 1
    printf '%s\n' "$content" | impact_write_file_atomic "$file" 600 root root
}

# impact_account_record_load ACCOUNT
#   Reads the record of ACCOUNT into IMPACT_ACCOUNT_RECORD (keys as listed
#   above). Needs root rights.
#   Result: 0 on success; 1 when the account has no record (it was not
#   enrolled with impact-add-user); 2 when the record is invalid or not safe
#   to use. The causes are in IMPACT_ACCOUNT_RECORD_ERRORS.
#   Example: impact_account_record_load alice && echo "${IMPACT_ACCOUNT_RECORD[GITHUB_NAME]}"
impact_account_record_load() {
    local account="$1" file key
    local -A parsed=()
    local -a order=() errors=()
    IMPACT_ACCOUNT_RECORD=()
    IMPACT_ACCOUNT_RECORD_ERRORS=()
    file="$(impact_account_record_file "$account")" || {
        IMPACT_ACCOUNT_RECORD_ERRORS=("'$(impact_display "$account")' cannot be an account name.")
        return 1
    }
    if [[ ! -e "$file" && ! -L "$file" ]]; then
        IMPACT_ACCOUNT_RECORD_ERRORS=("The account '$account' has no record: it was not enrolled with impact-add-user.")
        return 1
    fi
    if ! impact_file_is_trusted "$file"; then
        IMPACT_ACCOUNT_RECORD_ERRORS=("The record is not safe to use: $IMPACT_CHECK_REASON")
        return 2
    fi
    if ! impact_kv_parse "$file" parsed order errors; then
        IMPACT_ACCOUNT_RECORD_ERRORS=("${errors[@]}")
        return 2
    fi
    for key in "${IMPACT_ACCOUNT_RECORD_KEYS[@]}"; do
        if [[ ! -v parsed[$key] ]]; then
            IMPACT_ACCOUNT_RECORD_ERRORS+=("The key $key is missing in $file.")
        fi
    done
    if ((${#IMPACT_ACCOUNT_RECORD_ERRORS[@]} == 0)); then
        if [[ "${parsed[ACCOUNT_RECORD_VERSION]}" != '1' ]]; then
            IMPACT_ACCOUNT_RECORD_ERRORS+=("Unknown format version '$(impact_display "${parsed[ACCOUNT_RECORD_VERSION]}")' in $file.")
        fi
        if [[ "${parsed[ACCOUNT]}" != "$account" ]]; then
            IMPACT_ACCOUNT_RECORD_ERRORS+=("$file names another account: '$(impact_display "${parsed[ACCOUNT]}")'.")
        fi
        if ! impact_valid_github_name "${parsed[GITHUB_NAME]}" || [[ "${parsed[GITHUB_NAME]}" != "${parsed[GITHUB_NAME],,}" ]]; then
            IMPACT_ACCOUNT_RECORD_ERRORS+=("GITHUB_NAME in $file is no GitHub name in lower case.")
        fi
        if ! [[ "${parsed[USER_NUMBER]}" =~ ^[0-9]{1,10}$ ]]; then
            IMPACT_ACCOUNT_RECORD_ERRORS+=("USER_NUMBER in $file is no number.")
        fi
        if [[ "${parsed[STATE]}" != 'enrolled' && "${parsed[STATE]}" != 'removed' ]]; then
            IMPACT_ACCOUNT_RECORD_ERRORS+=("STATE in $file is neither enrolled nor removed.")
        fi
        if ! [[ "${parsed[CHANGED]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
            IMPACT_ACCOUNT_RECORD_ERRORS+=("CHANGED in $file is no time such as 2026-01-31T14:05:09Z.")
        fi
    fi
    if ((${#IMPACT_ACCOUNT_RECORD_ERRORS[@]} > 0)); then
        return 2
    fi
    for key in "${IMPACT_ACCOUNT_RECORD_KEYS[@]}"; do
        IMPACT_ACCOUNT_RECORD[$key]="${parsed[$key]}"
    done
    return 0
}

# impact_account_github_name ACCOUNT
#   Prints the GitHub name noted for ACCOUNT (lower case). Needs root rights.
#   Result: failure when the account has no valid record.
#   Example: name="$(impact_account_github_name alice)"
impact_account_github_name() {
    # The function runs inside "$( ... )" most of the time; the record it
    # loads is then visible to this call only.
    impact_account_record_load "$1" || return 1
    printf '%s\n' "${IMPACT_ACCOUNT_RECORD[GITHUB_NAME]}"
}

# impact_account_records
#   Prints the names of all accounts that have a record, one per line,
#   sorted. Needs root rights.
impact_account_records() {
    local file name
    [[ -d "$IMPACT_ACCOUNTS_DIR" ]] || return 0
    # "nullglob": a pattern without any match expands to nothing.
    shopt -s nullglob
    for file in "$IMPACT_ACCOUNTS_DIR"/*.conf; do
        name="$(basename -- "$file" .conf)"
        if impact__lookup_name_ok "$name"; then
            printf '%s\n' "$name"
        fi
    done | sort
    shopt -u nullglob
}

# =============================================================================
# SSH public keys
# =============================================================================

# impact_key_fingerprint KEY_LINE
#   Prints the SHA256 fingerprint of a public key line, in the form that
#   "ssh-keygen -l" and the GUI show: SHA256:<43 characters>.
#   Result: failure when the tool ssh-keygen does not accept the line.
#   Example: impact_key_fingerprint "ssh-ed25519 AAAAC3Nza..."
impact_key_fingerprint() {
    local output fingerprint
    # "-l" prints the fingerprint, "-f /dev/stdin" reads the key from the
    # text handed over with "<<<".
    output="$(ssh-keygen -l -E sha256 -f /dev/stdin <<<"$1" 2>/dev/null)" || return 1
    # The output looks like: 256 SHA256:abc... comment (ED25519)
    # "read" splits the line at blanks; "_" takes the words that are not needed.
    read -r _ fingerprint _ <<<"$output"
    impact_valid_fingerprint "$fingerprint" || return 1
    printf '%s\n' "$fingerprint"
}

# impact_parse_ed25519_key TEXT
#   Checks that TEXT is exactly one public key of the type ssh-ed25519 (the
#   type the GUI creates) in its plain form:
#       ssh-ed25519 <key data> [comment]
#   Refused, each with its own explanation in IMPACT_KEY_ERROR: no key; more
#   than one line; a private key; another key type; a line that starts with
#   options (as an authorized_keys line may); key data of the wrong shape; a
#   second key hidden in the comment.
#   Line ends of Windows and blanks around the line are tolerated.
#   Result on success: IMPACT_KEY_LINE ("ssh-ed25519 <key data>", without
#   the comment), IMPACT_KEY_BLOB, IMPACT_KEY_COMMENT (only letters, digits
#   and @ . _ + = : -; at most 64 characters) and IMPACT_KEY_FINGERPRINT.
#   Example: impact_parse_ed25519_key "$(cat -- "$key_file")"
impact_parse_ed25519_key() {
    local text="$1" line candidate='' count=0
    local key_type blob comment
    IMPACT_KEY_LINE=''
    IMPACT_KEY_BLOB=''
    IMPACT_KEY_COMMENT=''
    IMPACT_KEY_FINGERPRINT=''
    IMPACT_KEY_ERROR=''

    if [[ "$text" == *'PRIVATE KEY'* ]]; then
        IMPACT_KEY_ERROR='This is a PRIVATE key. A private key must never leave the PC of its owner. The public key is needed: the file whose name ends in .pub. This key pair should now be replaced by a new one.'
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(impact_trim "$line")"
        if [[ -z "$line" ]]; then
            continue
        fi
        count=$((count + 1))
        candidate="$line"
    done <<<"$text"
    if ((count == 0)); then
        IMPACT_KEY_ERROR='No key was given: the text is empty.'
        return 1
    fi
    if ((count > 1)); then
        IMPACT_KEY_ERROR="The text has $count lines with content. Exactly one public key on one line is expected."
        return 1
    fi
    if [[ "$candidate" =~ [[:cntrl:]] ]]; then
        IMPACT_KEY_ERROR='The key line contains a control character (for example a tab).'
        return 1
    fi

    # Split the line at blanks: first word, second word, and the rest.
    read -r key_type blob comment <<<"$candidate"
    if [[ "$key_type" != 'ssh-ed25519' ]]; then
        if [[ "$candidate" == *' ssh-ed25519 '* ]]; then
            IMPACT_KEY_ERROR='The line starts with options before the key type. Only a plain key line is accepted: ssh-ed25519 <key data> [comment].'
        elif [[ "$key_type" =~ ^(ssh-rsa|ssh-dss|ecdsa-sha2-.*|sk-.*)$ ]]; then
            IMPACT_KEY_ERROR="The key has the type '$key_type'. Only keys of the type ssh-ed25519 are accepted; the GUI creates this type."
        else
            IMPACT_KEY_ERROR='This is no public key line. Expected: ssh-ed25519 <key data> [comment].'
        fi
        return 1
    fi
    # The key data of an ed25519 key always has 68 characters and always
    # starts with the same 25 characters, which encode the key type.
    if ! [[ "$blob" =~ ^AAAAC3NzaC1lZDI1NTE5AAAAI[A-P][A-Za-z0-9+/]{42}$ ]]; then
        IMPACT_KEY_ERROR='The key data does not have the shape of an ssh-ed25519 public key (68 characters that start with AAAAC3NzaC1lZDI1NTE5). The line may be cut off or damaged.'
        return 1
    fi
    if [[ "$comment" =~ (ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-|sk-ssh-|sk-ecdsa-|AAAA[A-Za-z0-9+/]{20}) ]]; then
        IMPACT_KEY_ERROR='The line seems to contain a second key after the first one. Exactly one key is expected.'
        return 1
    fi
    local fingerprint
    if ! fingerprint="$(impact_key_fingerprint "ssh-ed25519 $blob")"; then
        IMPACT_KEY_ERROR='The tool ssh-keygen does not accept this key. The line may be damaged.'
        return 1
    fi
    # Keep only harmless characters of the comment; blanks become "_".
    comment="${comment// /_}"
    comment="${comment//[^A-Za-z0-9@._+=:-]/}"
    IMPACT_KEY_LINE="ssh-ed25519 $blob"
    IMPACT_KEY_BLOB="$blob"
    IMPACT_KEY_COMMENT="${comment:0:64}"
    IMPACT_KEY_FINGERPRINT="$fingerprint"
    return 0
}

# impact_ed25519_keys_in_text TEXT
#   Prints every plain ssh-ed25519 key line found in a text of several lines
#   (for example the answer of https://github.com/<name>.keys), one per line
#   in the form "ssh-ed25519 <key data>". Lines of other key types and
#   damaged lines are skipped.
#   Result: failure when no ed25519 key was found.
#   Example: impact_ed25519_keys_in_text "$downloaded" | while read -r key; do ...
impact_ed25519_keys_in_text() {
    local line found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(impact_trim "$line")"
        if [[ "$line" == 'ssh-ed25519 '* ]] && impact_parse_ed25519_key "$line"; then
            printf '%s\n' "$IMPACT_KEY_LINE"
            found=1
        fi
    done <<<"$1"
    ((found == 1))
}

# =============================================================================
# Working in a person's home folder
# =============================================================================

# impact_run_as ACCOUNT COMMAND [ARGUMENTS...]
#   Runs a command with the rights of ACCOUNT (user number, group and all
#   memberships), in the folder "/", with a small fixed environment: HOME,
#   USER, LOGNAME, PATH, LC_ALL and SHELL. Standard input and output are
#   passed through. Needs root rights. It works for accounts with a locked
#   password and for expired accounts.
#   Result: the exit code of the command.
#   Example: impact_run_as alice git -C /home/alice/Repositories/Example-Model status
impact_run_as() {
    local account="$1" home
    shift
    if ((EUID != 0)); then
        impact_error "impact_run_as needs root rights."
        return 1
    fi
    home="$(impact_account_home "$account")" || {
        impact_error "The account '$(impact_display "$account")' does not exist."
        return 1
    }
    # "( ... )" runs in a copy of the script, so the "cd" does not move the
    # command itself. "exec" replaces that copy with runuser. "env -i" starts
    # the command with an empty environment plus the listed variables.
    (
        cd / || exit 1
        exec runuser -u "$account" -- env -i \
            HOME="$home" USER="$account" LOGNAME="$account" \
            PATH="$IMPACT_SAFE_PATH" LC_ALL=C SHELL=/bin/bash "$@"
    )
}

# The script below runs with the rights of the person. It receives:
#   $1 action (mkdir, write, read, remove, exists)   $2 home folder
#   $3 path below the home folder                    $4 mode
# It walks from the home folder down to the target and refuses every folder
# on the way that is a symbolic link or belongs to another account. Exit
# codes: 0 done, 3 refused, 4 the file does not exist, 1 other failure.
# The text is stored in a variable with a here-document; 'END' in quotes
# keeps every character as written.
IMPACT__USER_FILE_SCRIPT="$(
    cat <<'END'
set -u
action="$1"; home="$2"; relative="$3"; mode="${4:-}"
umask 077
refuse() { printf 'refused: %s\n' "$1" >&2; exit 3; }
if [ -L "$home" ] || [ ! -d "$home" ] || [ ! -O "$home" ]; then
    refuse "the home folder $home is missing, is a symbolic link, or belongs to another account"
fi
IFS=/ read -r -a parts <<<"$relative"
last=$(( ${#parts[@]} - 1 ))
current="$home"
index=0
while [ "$index" -lt "$last" ]; do
    current="$current/${parts[$index]}"
    if [ -L "$current" ]; then
        refuse "$current is a symbolic link"
    elif [ -e "$current" ]; then
        if [ ! -d "$current" ] || [ ! -O "$current" ]; then
            refuse "$current is no folder of this account"
        fi
    elif [ "$action" = mkdir ]; then
        mkdir -m "$mode" -- "$current" || exit 1
    elif [ "$action" = write ]; then
        refuse "the folder $current does not exist"
    elif [ "$action" = remove ]; then
        exit 0
    else
        exit 4
    fi
    index=$(( index + 1 ))
done
target="$current/${parts[$last]}"
case "$action" in
    mkdir)
        if [ -L "$target" ]; then
            refuse "$target is a symbolic link"
        elif [ -e "$target" ]; then
            if [ ! -d "$target" ] || [ ! -O "$target" ]; then
                refuse "$target exists and is no folder of this account"
            fi
        else
            mkdir -m "$mode" -- "$target" || exit 1
        fi
        ;;
    write)
        if [ -L "$target" ]; then
            refuse "$target is a symbolic link"
        elif [ -e "$target" ]; then
            if [ ! -f "$target" ] || [ ! -O "$target" ]; then
                refuse "$target exists and is no plain file of this account"
            fi
        fi
        temporary="$(mktemp -- "$current/.impact-tmp.XXXXXXXXXX")" || exit 1
        if cat >"$temporary" && chmod -- "$mode" "$temporary" && mv -f -T -- "$temporary" "$target"; then
            exit 0
        fi
        rm -f -- "$temporary"
        exit 1
        ;;
    read)
        if [ -L "$target" ]; then
            refuse "$target is a symbolic link"
        elif [ ! -e "$target" ]; then
            exit 4
        elif [ ! -f "$target" ] || [ ! -O "$target" ]; then
            refuse "$target is no plain file of this account"
        fi
        cat -- "$target" || exit 1
        ;;
    exists)
        if [ -L "$target" ]; then
            refuse "$target is a symbolic link"
        elif [ ! -e "$target" ]; then
            exit 4
        elif [ ! -f "$target" ] || [ ! -O "$target" ]; then
            refuse "$target is no plain file of this account"
        fi
        ;;
    remove)
        if [ -L "$target" ]; then
            rm -f -- "$target" || exit 1
        elif [ ! -e "$target" ]; then
            exit 0
        elif [ -f "$target" ]; then
            rm -f -- "$target" || exit 1
        else
            refuse "$target is no plain file"
        fi
        ;;
    *)
        exit 1
        ;;
esac
exit 0
END
)"
readonly IMPACT__USER_FILE_SCRIPT

# impact__user_file ACTION ACCOUNT PATH [MODE]
#   Internal: checks the request and runs the script above as the person.
#   PATH must lie inside the home folder of ACCOUNT and consist of letters,
#   digits, ".", "_" and "-" between the slashes.
impact__user_file() {
    local action="$1" account="$2" path="$3" mode="${4:-}"
    local home relative
    home="$(impact_account_home "$account")" || {
        impact_error "The account '$(impact_display "$account")' does not exist."
        return 1
    }
    if ! impact_valid_abs_path "$home" || [[ "$home" == '/' ]]; then
        impact_error "The home folder '$(impact_display "$home")' of '$account' is no usable path."
        return 1
    fi
    if ! impact_valid_abs_path "$path" || ! impact_path_is_below "$path" "$home"; then
        impact_error "'$(impact_display "$path")' is no clean path inside the home folder $home."
        return 1
    fi
    if [[ -n "$mode" ]] && ! [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
        impact_error "'$mode' is no file mode."
        return 1
    fi
    relative="${path#"$home"/}"   # the part of the path below the home folder
    impact_run_as "$account" /bin/bash -c "$IMPACT__USER_FILE_SCRIPT" impact-user-file \
        "$action" "$home" "$relative" "$mode"
}

# impact_user_mkdir ACCOUNT PATH MODE
#   Creates a folder inside the person's home folder, as the person. Missing
#   folders on the way are created with the same mode. An existing folder of
#   the person is accepted as it is (its mode is not changed).
#   Result: 0 done; 3 refused (a symbolic link or a foreign owner on the
#   way; the reason is printed); 1 other failure.
#   Example: impact_user_mkdir alice /home/alice/.ssh 700
impact_user_mkdir() {
    impact__user_file mkdir "$1" "$2" "$3"
}

# impact_user_write_file ACCOUNT PATH MODE
#   Writes standard input to a file inside the person's home folder, as the
#   person, in one step (temporary file, then rename). The folder must exist
#   (see impact_user_mkdir).
#   Result: 0 done; 3 refused (the reason is printed); 1 other failure.
#   Example: impact_user_write_file alice /home/alice/.ssh/authorized_keys 600 <"$IMPACT_TMP"
impact_user_write_file() {
    impact__user_file write "$1" "$2" "$3"
}

# impact_user_read_file ACCOUNT PATH
#   Prints a file from the person's home folder, read as the person.
#   Result: 0 done; 4 the file does not exist; 3 refused; 1 other failure.
#   Example: keys="$(impact_user_read_file alice /home/alice/.ssh/authorized_keys)" || status=$?
impact_user_read_file() {
    impact__user_file read "$1" "$2"
}

# impact_user_file_exists ACCOUNT PATH
#   Result: 0 when the path is a plain file of the person; 4 when nothing is
#   there; 3 when something else is there (the reason is printed).
impact_user_file_exists() {
    impact__user_file exists "$1" "$2"
}

# impact_user_remove_file ACCOUNT PATH
#   Removes a file (or a symbolic link itself) inside the person's home
#   folder, as the person. A missing file counts as done.
#   Result: 0 done; 3 refused; 1 other failure.
#   Example: impact_user_remove_file alice /home/alice/.ssh/id_ed25519_alice-example
impact_user_remove_file() {
    impact__user_file remove "$1" "$2"
}
