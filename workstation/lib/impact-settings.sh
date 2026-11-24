#!/bin/bash
# =============================================================================
# impact-settings.sh: the site settings file, the model file, and the rules
# for every name and path that comes from input
#
# Purpose
#   1. Rules ("validators") for account names, GitHub names, model names,
#      paths, GitHub addresses and the other values the commands accept.
#   2. A reader for files made of KEY=value lines. The file is read as text,
#      line by line. It is never executed, so a value can never run a command.
#   3. Reader, checker and writer for /etc/impact/impact.conf (site settings)
#      and for <MODEL_DIR>/<model>/model.conf (one per model).
#
# Who runs it
#   Nobody directly. impact-common.sh loads it.
#
# Usage (inside a command, after loading impact-common.sh)
#   impact_require_conf                      # stops when the file is invalid
#   echo "${IMPACT_CONF[SHARED_GROUP]}"      # one value
#   impact_split_list "${IMPACT_CONF[SHARED_ROOTS]}" roots
#   impact_require_model "Example-Model"     # fills IMPACT_MODEL
#
# What it changes on the system
#   Loading changes nothing. impact_conf_write and impact_model_conf_write
#   replace a settings file in one step when a command calls them.
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

# The values of the site settings file after impact_conf_load, found by key:
# "${IMPACT_CONF[PORT_MIN]}". An associative array is a list whose entries
# are found by a name.
declare -gA IMPACT_CONF=()
IMPACT_CONF_ERRORS=()      # why the file is invalid, one text per problem
IMPACT_CONF_WARNINGS=()    # notes that do not make the file invalid

# The values of one model file after impact_model_load.
declare -gA IMPACT_MODEL=()
IMPACT_MODEL_ERRORS=()
IMPACT_MODEL_WARNINGS=()

# Set by the validators that explain their answer.
IMPACT_CHECK_REASON=''

# All keys of the site settings file, in the order in which a new file lists
# them, and the keys that may be missing or empty.
readonly -a IMPACT_CONF_KEYS=(
    IMPACT_CONF_VERSION MIN_GUI_VERSION ACCESS_MODE REPO_BASE MODEL_DIR
    SHARED_GROUP SHARED_ROOTS MIN_FREE_GB PORT_MIN PORT_MAX
    KNOWN_DIRECT_CONTAINERS ADMIN_CONTACT DEPUTY_CONTACT
)
readonly -a IMPACT_CONF_OPTIONAL_KEYS=(KNOWN_DIRECT_CONTAINERS DEPUTY_CONTACT)

# The same for the model file.
readonly -a IMPACT_MODEL_KEYS=(MODEL_CONF_VERSION REPO_URL BRANCH STORAGE_NAME STORAGE_ROOTS)
readonly -a IMPACT_MODEL_OPTIONAL_KEYS=(BRANCH)

# =============================================================================
# Validators: each answers "is this text acceptable?" with success or failure
# and prints nothing. They are pure: they look only at the text.
# =============================================================================

# impact_valid_account_name TEXT
#   A Linux account name as Ubuntu accepts it: a lower-case letter, then up
#   to 31 lower-case letters, digits, "-" or "_".
#   Example: impact_valid_account_name alice   succeeds
impact_valid_account_name() {
    # "=~" compares with a regular expression: "^" start, "$" end, "[a-z]"
    # one character of the set, "{0,31}" zero to 31 repetitions.
    [[ "$1" =~ ^[a-z][-a-z0-9_]{0,31}$ ]]
}

# impact_valid_group_name TEXT
#   A Linux group name; the same rule as for account names.
impact_valid_group_name() {
    [[ "$1" =~ ^[a-z][-a-z0-9_]{0,31}$ ]]
}

# impact_valid_github_name TEXT
#   A GitHub user name: 1 to 39 letters, digits, "-" or "_", with a letter or
#   digit at both ends. Upper and lower case are both accepted, because
#   GitHub ignores the case of names.
#   Example: impact_valid_github_name alice-example   succeeds
impact_valid_github_name() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]{0,37}[A-Za-z0-9])?$ ]]
}

# impact_valid_model_name TEXT
#   A model name: the folder name people see under their repository folder.
#   A letter or digit, then up to 79 letters, digits, "_", "." or "-". A name
#   that ends in ".partial" is refused, because impact-get-repo uses
#   "<model>.partial" as the working name of an unfinished copy.
#   Example: impact_valid_model_name Example-Model   succeeds
impact_valid_model_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$ && "$1" != *.partial ]]
}

# impact_valid_storage_name TEXT
#   The folder name of a model on the shared storage: a letter or digit, then
#   up to 39 letters, digits, "_", "." or "-".
impact_valid_storage_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$ ]]
}

# impact_valid_abs_path TEXT
#   An absolute path made of letters, digits, ".", "_", "/" and "-" only.
#   Refused as well: "/" alone, a "/" at the end, "//", and the parts "." and
#   "..". Without these, two different texts never mean the same folder and
#   no path can climb out of its parent.
#   Example: impact_valid_abs_path /mnt/disk_a/shared   succeeds
impact_valid_abs_path() {
    local path="$1"
    [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    ((${#path} <= 255)) || return 1
    [[ "$path" != */ && "$path" != *//* ]] || return 1
    # With a "/" added at the end, a part "." or ".." always shows up as
    # "/./" or "/../", wherever it stands.
    [[ "$path/" != */./* && "$path/" != */../* ]]
}

# impact_expand_repo_base_template TEMPLATE HOME ACCOUNT
#   Prints TEMPLATE with "%h" replaced by HOME and "%u" replaced by ACCOUNT.
#   Pure text work; see impact_repo_base_for in impact-accounts.sh for the
#   version that looks the account up.
#   Example: impact_expand_repo_base_template %h/Repositories /home/alice alice
#            prints /home/alice/Repositories
impact_expand_repo_base_template() {
    local text="$1"
    # "${text//pattern/replacement}" replaces every match. "[%]" is written
    # with brackets because a pattern that starts with a bare "%" has a
    # special meaning for bash. The replacement is quoted so that no
    # character in it is treated specially.
    text="${text//[%]h/"$2"}"
    text="${text//[%]u/"$3"}"
    printf '%s' "$text"
}

# impact_valid_repo_base TEXT
#   The REPO_BASE setting: letters, digits, ".", "_", "/", "-" and the two
#   tokens "%h" (home folder) and "%u" (account name). After replacing the
#   tokens the result must be an absolute path.
#   Example: impact_valid_repo_base %h/Repositories   succeeds
impact_valid_repo_base() {
    local text="$1" rest expanded
    [[ "$text" =~ ^[A-Za-z0-9._/%-]+$ ]] || return 1
    # Remove the two known tokens; any "%" that is left belongs to an
    # unknown token.
    rest="${text//[%]h/}"
    rest="${rest//[%]u/}"
    [[ "$rest" != *%* ]] || return 1
    expanded="$(impact_expand_repo_base_template "$text" /home/example example)"
    impact_valid_abs_path "$expanded"
}

# impact_valid_branch_name TEXT
#   A git branch name that is safe to pass to git: starts with a letter or
#   digit; letters, digits, ".", "_", "/" and "-"; at most 100 characters;
#   no "..", no "//", no part that starts with "." or ends in ".lock", no "/"
#   or "." at the end; and "HEAD" is refused.
#   Example: impact_valid_branch_name feature/new-inputs   succeeds
impact_valid_branch_name() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ ]] || return 1
    [[ "$name" != *..* && "$name" != *//* && "$name" != */ && "$name" != *. ]] || return 1
    [[ "$name" != */.* && "$name" != *.lock && "$name" != *.lock/* ]] || return 1
    [[ "$name" != 'HEAD' ]]
}

# impact_valid_whole_number TEXT MINIMUM MAXIMUM
#   A whole number without sign and without leading zeros, between MINIMUM
#   and MAXIMUM (both included).
#   Example: impact_valid_whole_number 8787 1024 65535   succeeds
impact_valid_whole_number() {
    # At most 9 digits, so the number always fits bash arithmetic.
    [[ "$1" =~ ^(0|[1-9][0-9]{0,8})$ ]] || return 1
    (($1 >= $2 && $1 <= $3))
}

# impact_valid_port TEXT
#   A port number for containers: 1024 to 65535.
impact_valid_port() {
    impact_valid_whole_number "$1" 1024 65535
}

# impact_valid_user_number TEXT
#   A user or group number for a person or a shared group: 1000 to 60000.
#   Numbers below 1000 belong to the system.
impact_valid_user_number() {
    impact_valid_whole_number "$1" 1000 60000
}

# impact_valid_gui_version TEXT
#   Three numbers with dots, for example 2.1.0.
impact_valid_gui_version() {
    [[ "$1" =~ ^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}$ ]]
}

# impact_valid_container_pattern TEXT
#   One name pattern for containers: letters, digits, "_", ".", "-" and the
#   wildcards "*" (any text) and "?" (one character).
impact_valid_container_pattern() {
    [[ "$1" =~ ^[A-Za-z0-9_.*?-]{1,128}$ ]]
}

# impact_valid_contact TEXT
#   A contact text for messages: 1 to 80 characters, valid UTF-8 (so names
#   with accents work), no control characters such as tabs or line breaks.
#   Example: impact_valid_contact "Alice Example (alice@example.org)"
impact_valid_contact() {
    local text="$1"
    [[ -n "$text" ]] || return 1
    if [[ "$text" =~ [[:cntrl:]] ]]; then
        return 1
    fi
    # iconv converts between character sets; converting UTF-8 to UTF-8 fails
    # exactly when the text is no valid UTF-8.
    printf '%s' "$text" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || return 1
    # Count characters, not bytes: for this function only, switch bash to a
    # UTF-8 locale. "local" limits the change to this function.
    local LC_ALL=C.UTF-8
    if [[ "$text" =~ [[:cntrl:]] ]]; then
        return 1
    fi
    ((${#text} <= 80))
}

# impact_valid_fingerprint TEXT
#   The SHA256 fingerprint of an SSH key as ssh-keygen prints it:
#   "SHA256:" followed by 43 characters.
impact_valid_fingerprint() {
    [[ "$1" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]
}

# impact_valid_repo_url TEXT
#   The stored form of a repository address:
#   git@github.com:<owner>/<repository>.git
#   Example: impact_valid_repo_url git@github.com:example-org/Example-Model.git
impact_valid_repo_url() {
    impact_parse_github_address "$1" || return 1
    [[ "$1" == "$IMPACT_GH_SSH_URL" ]]
}

# impact_parse_github_address TEXT
#   Reads a GitHub repository address in one of two forms:
#     git@github.com:<owner>/<repository>.git     (".git" may be missing)
#     https://github.com/<owner>/<repository>     (".git" or "/" may follow)
#   Owner and repository consist of letters, digits, ".", "_" and "-". Any
#   other host, form or character is refused.
#   Result on success:
#     IMPACT_GH_OWNER, IMPACT_GH_REPO   the two names
#     IMPACT_GH_SSH_URL     git@github.com:<owner>/<repository>.git
#     IMPACT_GH_HTTPS_URL   https://github.com/<owner>/<repository>.git
#   Result on failure: exit status 1 and the four variables are empty.
#   Example: impact_parse_github_address https://github.com/example-org/Example-Model
impact_parse_github_address() {
    local text="$1" owner repo
    IMPACT_GH_OWNER=''
    IMPACT_GH_REPO=''
    IMPACT_GH_SSH_URL=''
    IMPACT_GH_HTTPS_URL=''
    # BASH_REMATCH holds the texts that matched the "( )" groups.
    if [[ "$text" =~ ^git@github\.com:([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$ ]]; then
        owner="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
    elif [[ "$text" =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/?$ ]]; then
        owner="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    repo="${repo%.git}"   # remove one ".git" at the end, when present
    # Refuse names that are empty, too long, start with "-" or mean "this
    # folder" or "parent folder".
    [[ -n "$repo" && "$repo" != '.' && "$repo" != '..' && "$repo" != -* ]] || return 1
    [[ "$owner" != '.' && "$owner" != '..' && "$owner" != -* && "$owner" != .* ]] || return 1
    ((${#owner} <= 39 && ${#repo} <= 100)) || return 1
    IMPACT_GH_OWNER="$owner"
    IMPACT_GH_REPO="$repo"
    IMPACT_GH_SSH_URL="git@github.com:$owner/$repo.git"
    IMPACT_GH_HTTPS_URL="https://github.com/$owner/$repo.git"
}

# =============================================================================
# Reader for KEY=value files
# =============================================================================

# impact_kv_parse FILE VALUES_NAME ORDER_NAME ERRORS_NAME
#   Reads a file of KEY=value lines as text. Rules:
#     empty lines and lines whose first visible character is "#" are skipped;
#     every other line is KEY=value; KEY is upper-case letters, digits and
#     "_" and starts with a letter; blanks around key and value are removed;
#     the value is everything after the first "="; no quotes, no escapes, no
#     variables, no comment at the end of a line.
#   Parameters: the file, and the NAMES of three variables of the caller:
#     an associative array for the values, an array for the keys in file
#     order, and an array for error texts (a line that breaks the rules, a
#     key that appears twice).
#   Result: success when the file was read without errors. All three
#   variables are emptied first.
#   Example:
#     declare -A values=(); order=(); errors=()
#     impact_kv_parse /etc/impact/impact.conf values order errors
impact_kv_parse() {
    local file="$1"
    # "local -n" gives this function a second name for a variable of the
    # caller. The long names avoid a clash with the caller's own names.
    local -n impact__kv_values="$2" impact__kv_order="$3" impact__kv_errors="$4"
    impact__kv_values=()
    impact__kv_order=()
    impact__kv_errors=()
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        impact__kv_errors+=("The file $file does not exist or cannot be read.")
        return 1
    fi
    local line key value number=0
    # "read -r" keeps backslashes as they are. "|| [[ -n $line ]]" also
    # handles a last line without a line end.
    while IFS= read -r line || [[ -n "$line" ]]; do
        number=$((number + 1))
        # Some Windows editors put three invisible bytes (a "byte order
        # mark") at the start of a file. Remove them from the first line.
        if ((number == 1)); then
            line="${line#$'\xef\xbb\xbf'}"
        fi
        line="$(impact_trim "$line")"
        if [[ -z "$line" || "$line" == '#'* ]]; then
            continue
        fi
        if [[ "$line" != *=* ]]; then
            impact__kv_errors+=("Line $number is neither a comment nor KEY=value: '$(impact_display "$line")'")
            continue
        fi
        key="$(impact_trim "${line%%=*}")"     # before the first "="
        value="$(impact_trim "${line#*=}")"    # after the first "="
        if ! [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            impact__kv_errors+=("Line $number: '$(impact_display "$key")' is no valid key (upper-case letters, digits and _).")
            continue
        fi
        if [[ -v impact__kv_values[$key] ]]; then
            impact__kv_errors+=("Line $number: the key $key appears a second time.")
            continue
        fi
        # shellcheck disable=SC2004
        # Reason for SC2004 ("$ is unnecessary"): the target is an associative
        # array reached through a second name, and its key needs the "$".
        impact__kv_values[$key]="$value"
        impact__kv_order+=("$key")
    done <"$file"
    ((${#impact__kv_errors[@]} == 0))
}

# impact__kv_render EXISTING_FILE VALUES_NAME KEYS_NAME HELP_FUNCTION HEADER_FUNCTION
#   Internal: prints the new content of a KEY=value file.
#   With an existing file: every line is kept as it is, except that the value
#   of a known key is replaced when it differs, and a second line for the
#   same known key is dropped. Comments, empty lines and lines with unknown
#   keys stay where they are. Known keys that the file lacks are added at the
#   end with their explanation.
#   Without an existing file: a header, then every key with its explanation.
impact__kv_render() {
    local file="$1"
    local -n impact__render_values="$2" impact__render_keys="$3"
    local help_function="$4" header_function="$5"
    local -A done_keys=()
    local line trimmed key value number=0
    if [[ -f "$file" && -r "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            number=$((number + 1))
            if ((number == 1)); then
                line="${line#$'\xef\xbb\xbf'}"
            fi
            trimmed="$(impact_trim "$line")"
            if [[ -z "$trimmed" || "$trimmed" == '#'* || "$trimmed" != *=* ]]; then
                printf '%s\n' "$line"
                continue
            fi
            key="$(impact_trim "${trimmed%%=*}")"
            value="$(impact_trim "${trimmed#*=}")"
            if ! impact_in_list "$key" "${impact__render_keys[@]}" || [[ ! -v impact__render_values[$key] ]]; then
                printf '%s\n' "$line"
                continue
            fi
            if [[ -v done_keys[$key] ]]; then
                continue
            fi
            done_keys[$key]=1
            if [[ "$value" == "${impact__render_values[$key]}" ]]; then
                printf '%s\n' "$line"
            else
                printf '%s=%s\n' "$key" "${impact__render_values[$key]}"
            fi
        done <"$file"
    else
        "$header_function"
    fi
    for key in "${impact__render_keys[@]}"; do
        if [[ -v done_keys[$key] || ! -v impact__render_values[$key] ]]; then
            continue
        fi
        printf '\n'
        "$help_function" "$key"
        printf '%s=%s\n' "$key" "${impact__render_values[$key]}"
    done
}

# impact_file_is_trusted FILE
#   Result: success when FILE can be trusted as input for commands that run
#   as root: a plain file (no symbolic link), owned by root, writable by root
#   only, in a folder with the same properties. Otherwise failure, with the
#   cause in IMPACT_CHECK_REASON.
#   Why: the commands act on the paths and names in these files. If another
#   account could change the file, it could steer what root does.
impact_file_is_trusted() {
    local file="$1" folder facts owner mode
    IMPACT_CHECK_REASON=''
    folder="$(dirname -- "$file")"
    if [[ -L "$file" || ! -f "$file" ]]; then
        IMPACT_CHECK_REASON="$file is missing or is no plain file."
        return 1
    fi
    local item
    for item in "$file" "$folder"; do
        # %u is the owner's number, %a the mode as an octal number.
        facts="$(stat -c '%u %a' -- "$item" 2>/dev/null)" || {
            IMPACT_CHECK_REASON="$item cannot be examined."
            return 1
        }
        owner="${facts%% *}"
        mode="${facts##* }"
        if [[ "$owner" != '0' ]]; then
            IMPACT_CHECK_REASON="$item belongs to the account number $owner; it must belong to root."
            return 1
        fi
        # "8#" reads the mode as an octal number; "& 8#022" picks the write
        # bits of the group and of all others.
        if (((8#$mode & 8#022) != 0)); then
            IMPACT_CHECK_REASON="$item (mode $mode) can be changed by accounts other than root."
            return 1
        fi
    done
    return 0
}

# =============================================================================
# The site settings file /etc/impact/impact.conf
# =============================================================================

# impact_conf_default KEY
#   Prints the value that impact-workstation-setup writes for KEY when the
#   administrator gives none. SHARED_ROOTS and ADMIN_CONTACT have no default:
#   they describe the site and must be given.
impact_conf_default() {
    case "$1" in
        IMPACT_CONF_VERSION) printf '1' ;;
        MIN_GUI_VERSION) printf '2.1.0' ;;
        ACCESS_MODE) printf 'tunnel' ;;
        REPO_BASE) printf '%s' '%h/Repositories' ;;
        MODEL_DIR) printf '/srv/impact/models' ;;
        SHARED_GROUP) printf 'impact' ;;
        MIN_FREE_GB) printf '200' ;;
        PORT_MIN) printf '8787' ;;
        PORT_MAX) printf '8830' ;;
        *) ;;
    esac
}

# impact_conf_check_value KEY VALUE
#   Checks one value of the site settings file against the rule of its key.
#   Result: success when the value is acceptable. Otherwise failure, and
#   IMPACT_CHECK_REASON holds the rule in plain words.
#   Example: impact_conf_check_value PORT_MIN 80   fails ("1024 to 65535")
impact_conf_check_value() {
    local key="$1" value="$2" entry
    local -a entries=()
    IMPACT_CHECK_REASON=''
    case "$key" in
        IMPACT_CONF_VERSION)
            [[ "$value" == '1' ]] && return 0
            IMPACT_CHECK_REASON="this version of the commands understands format version 1 only"
            ;;
        MIN_GUI_VERSION)
            impact_valid_gui_version "$value" && return 0
            IMPACT_CHECK_REASON="expected three numbers with dots, for example 2.1.0"
            ;;
        ACCESS_MODE)
            [[ "$value" == 'tunnel' || "$value" == 'direct' ]] && return 0
            IMPACT_CHECK_REASON="expected tunnel or direct"
            ;;
        REPO_BASE)
            impact_valid_repo_base "$value" && return 0
            IMPACT_CHECK_REASON="expected a path that is absolute after replacing %h (home folder) and %u (account name), made of letters, digits and . _ / - only, for example %h/Repositories"
            ;;
        MODEL_DIR)
            impact_valid_abs_path "$value" && return 0
            IMPACT_CHECK_REASON="expected an absolute path made of letters, digits and . _ / - only, without .. and without / at the end"
            ;;
        SHARED_GROUP)
            impact_valid_group_name "$value" && return 0
            IMPACT_CHECK_REASON="expected a group name: a lower-case letter, then up to 31 lower-case letters, digits, - or _"
            ;;
        SHARED_ROOTS)
            IMPACT_CHECK_REASON="expected one or more absolute paths separated by commas, without spaces, each made of letters, digits and . _ / - only"
            impact_split_list "$value" entries
            ((${#entries[@]} >= 1)) || return 1
            for entry in "${entries[@]}"; do
                impact_valid_abs_path "$entry" || return 1
            done
            IMPACT_CHECK_REASON=''
            return 0
            ;;
        MIN_FREE_GB)
            impact_valid_whole_number "$value" 0 100000 && return 0
            IMPACT_CHECK_REASON="expected a whole number from 0 to 100000"
            ;;
        PORT_MIN | PORT_MAX)
            impact_valid_port "$value" && return 0
            IMPACT_CHECK_REASON="expected a port number from 1024 to 65535"
            ;;
        KNOWN_DIRECT_CONTAINERS)
            [[ -z "$value" ]] && return 0
            IMPACT_CHECK_REASON="expected nothing, or container name patterns separated by commas, made of letters, digits and _ . - * ? only"
            impact_split_list "$value" entries
            for entry in "${entries[@]}"; do
                impact_valid_container_pattern "$entry" || return 1
            done
            IMPACT_CHECK_REASON=''
            return 0
            ;;
        ADMIN_CONTACT)
            impact_valid_contact "$value" && return 0
            IMPACT_CHECK_REASON="expected a text of 1 to 80 characters without control characters"
            ;;
        DEPUTY_CONTACT)
            [[ -z "$value" ]] && return 0
            impact_valid_contact "$value" && return 0
            IMPACT_CHECK_REASON="expected nothing, or a text of at most 80 characters without control characters"
            ;;
        *)
            IMPACT_CHECK_REASON="unknown key"
            ;;
    esac
    return 1
}

# impact_conf_validate VALUES_NAME
#   Checks a complete set of site settings: every required key is present,
#   every value follows its rule, and the port range is in order (PORT_MIN
#   not above PORT_MAX, at most 200 ports).
#   Parameter: the NAME of an associative array with the values.
#   Result: success when everything is valid. Otherwise failure, with one
#   text per problem in IMPACT_CONF_ERRORS.
impact_conf_validate() {
    local -n impact__validate_values="$1"
    local key
    IMPACT_CONF_ERRORS=()
    for key in "${IMPACT_CONF_KEYS[@]}"; do
        if [[ ! -v impact__validate_values[$key] ]]; then
            if ! impact_in_list "$key" "${IMPACT_CONF_OPTIONAL_KEYS[@]}"; then
                IMPACT_CONF_ERRORS+=("The required key $key is missing.")
            fi
            continue
        fi
        if ! impact_conf_check_value "$key" "${impact__validate_values[$key]}"; then
            IMPACT_CONF_ERRORS+=("$key has the value '$(impact_display "${impact__validate_values[$key]}")': $IMPACT_CHECK_REASON.")
        fi
    done
    # The range check needs two valid numbers.
    if [[ -v impact__validate_values[PORT_MIN] && -v impact__validate_values[PORT_MAX] ]] &&
        impact_valid_port "${impact__validate_values[PORT_MIN]}" &&
        impact_valid_port "${impact__validate_values[PORT_MAX]}"; then
        local low="${impact__validate_values[PORT_MIN]}" high="${impact__validate_values[PORT_MAX]}"
        if ((low > high)); then
            IMPACT_CONF_ERRORS+=("PORT_MIN ($low) is larger than PORT_MAX ($high).")
        elif ((high - low + 1 > 200)); then
            IMPACT_CONF_ERRORS+=("The port range $low to $high has $((high - low + 1)) ports; at most 200 are allowed.")
        fi
    fi
    ((${#IMPACT_CONF_ERRORS[@]} == 0))
}

# impact_conf_parse_file FILE
#   Reads and checks a site settings file.
#   Result on success: IMPACT_CONF holds every key (optional keys that the
#   file lacks are present with an empty value); IMPACT_CONF_WARNINGS names
#   unknown keys, which are ignored.
#   Result on failure: exit status 1, IMPACT_CONF is empty, and
#   IMPACT_CONF_ERRORS holds one text per problem.
#   This function does not look at owner and mode of the file; see
#   impact_conf_load for the version the commands use.
impact_conf_parse_file() {
    local file="$1" key
    local -A parsed=()
    local -a order=() errors=()
    IMPACT_CONF=()
    IMPACT_CONF_ERRORS=()
    IMPACT_CONF_WARNINGS=()
    if ! impact_kv_parse "$file" parsed order errors; then
        IMPACT_CONF_ERRORS=("${errors[@]}")
        return 1
    fi
    for key in "${order[@]}"; do
        if ! impact_in_list "$key" "${IMPACT_CONF_KEYS[@]}"; then
            IMPACT_CONF_WARNINGS+=("The key $key is unknown and is ignored.")
            unset -v "parsed[$key]"
        fi
    done
    if ! impact_conf_validate parsed; then
        return 1
    fi
    for key in "${IMPACT_CONF_KEYS[@]}"; do
        IMPACT_CONF[$key]="${parsed[$key]:-}"
    done
    return 0
}

# impact_conf_load
#   Reads /etc/impact/impact.conf into IMPACT_CONF after checking that the
#   file can be trusted (see impact_file_is_trusted).
#   Result: success, or failure with the causes in IMPACT_CONF_ERRORS.
#   Example: if impact_conf_load; then echo "${IMPACT_CONF[ACCESS_MODE]}"; fi
impact_conf_load() {
    IMPACT_CONF=()
    IMPACT_CONF_ERRORS=()
    IMPACT_CONF_WARNINGS=()
    if [[ ! -e "$IMPACT_CONF_FILE" && ! -L "$IMPACT_CONF_FILE" ]]; then
        IMPACT_CONF_ERRORS=("The settings file $IMPACT_CONF_FILE does not exist.")
        return 1
    fi
    if ! impact_file_is_trusted "$IMPACT_CONF_FILE"; then
        IMPACT_CONF_ERRORS=("The settings file is not safe to use: $IMPACT_CHECK_REASON")
        return 1
    fi
    impact_conf_parse_file "$IMPACT_CONF_FILE"
}

# impact_require_conf
#   Loads the site settings or stops the command with exit code 3 ("the
#   workstation is not prepared") after printing every problem. Warnings
#   about unknown keys are printed and the command continues.
#   Example: impact_require_conf
impact_require_conf() {
    local text
    if ! impact_conf_load; then
        for text in "${IMPACT_CONF_ERRORS[@]}"; do
            impact_error "$text"
        done
        IMPACT_RESULT_REASON='not_prepared'
        if ((EUID == 0)); then
            impact_die "$IMPACT_EXIT_NOT_PREPARED" \
                "This workstation is not prepared for the IMPACT commands: the settings file is missing or invalid." \
                "Run 'sudo impact-workstation-setup --help' and set the workstation up, or correct the lines named above."
        fi
        impact_die "$IMPACT_EXIT_NOT_PREPARED" \
            "This workstation is not prepared for IMPACT Docker GUI 2.1: the settings file is missing or invalid." \
            "Please contact the administrator of the workstation."
    fi
    for text in "${IMPACT_CONF_WARNINGS[@]}"; do
        impact_warn "$IMPACT_CONF_FILE: $text"
    done
}

# impact__conf_header
#   Internal: prints the comment block at the top of a new settings file.
impact__conf_header() {
    # A "here-document": the lines up to the end mark are printed as they
    # are. The quotes around 'END' switch off every replacement inside.
    cat <<'END'
# IMPACT Docker GUI: site settings of this workstation
#
# Read by the IMPACT workstation commands and by the GUI on each PC.
#
# Format: one KEY=value per line. The value is everything after the first
# "=". Write it without quotes. A comment needs its own line and starts
# with "#". The file is read as text and is never executed.
#
# Change a value with the setup command, for example:
#   sudo impact-workstation-setup --min-free-gb 300
# The command checks every value and updates the SSH rules when the port
# range changes. After a change by hand, run "sudo impact-check".
END
}

# impact__conf_help KEY
#   Internal: prints the comment lines that explain one key in the file.
impact__conf_help() {
    case "$1" in
        IMPACT_CONF_VERSION)
            printf '%s\n' '# Format version of this file. Always 1.'
            ;;
        MIN_GUI_VERSION)
            printf '%s\n' '# Oldest version of the GUI that may start containers on this workstation.' \
                '# Three numbers with dots.'
            ;;
        ACCESS_MODE)
            printf '%s\n' '# How new containers are published.' \
                '#   tunnel: reachable only from the workstation itself; the GUI opens an' \
                '#           SSH tunnel (an encrypted connection) from the PC.' \
                '#   direct: reachable from the network, as in version 2.0.'
            ;;
        REPO_BASE)
            printf '%s\n' '# Folder that holds the working copies of each person.' \
                '# %h stands for the home folder of the person, %u for the account name.'
            ;;
        MODEL_DIR)
            printf '%s\n' '# Folder with one subfolder per model (model.conf and extras),' \
                '# written by the administrator, readable for the shared group.'
            ;;
        SHARED_GROUP)
            printf '%s\n' '# Linux group of all enrolled people. It owns the shared storage, and the' \
                '# SSH rules apply to its members.'
            ;;
        SHARED_ROOTS)
            printf '%s\n' '# The storage roots: folders on the large disks that hold one folder per' \
                '# model. Several roots are separated by commas, without spaces.'
            ;;
        MIN_FREE_GB)
            printf '%s\n' '# The GUI warns before a start when the chosen disk has less free space' \
                '# than this many gigabytes.'
            ;;
        PORT_MIN)
            printf '%s\n' '# First port of the range for containers on the workstation.'
            ;;
        PORT_MAX)
            printf '%s\n' '# Last port of the range (at most 200 ports in the range).'
            ;;
        KNOWN_DIRECT_CONTAINERS)
            printf '%s\n' '# Name patterns of containers outside the GUI that may publish ports to the' \
                '# network, separated by commas. * stands for any text, ? for one character.' \
                '# Example: data_preparation_*   Empty means: none.'
            ;;
        ADMIN_CONTACT)
            printf '%s\n' '# Shown in messages that tell a colleague whom to contact.'
            ;;
        DEPUTY_CONTACT)
            printf '%s\n' '# Optional second contact for the same messages. Empty means: none.'
            ;;
        *) ;;
    esac
}

# impact_conf_render VALUES_NAME [EXISTING_FILE]
#   Prints the content of a site settings file for the given values. With an
#   existing file, its comments and unknown lines are kept (see
#   impact__kv_render). Nothing is written.
#   Example: impact_conf_render values /etc/impact/impact.conf >"$IMPACT_TMP"
impact_conf_render() {
    impact__kv_render "${2:-}" "$1" IMPACT_CONF_KEYS impact__conf_help impact__conf_header
}

# impact_conf_needs_write FILE VALUES_NAME
#   Result: success when writing the values would change FILE (or FILE does
#   not exist). Use it to decide whether there is anything to do.
impact_conf_needs_write() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 0
    ! impact_conf_render "$2" "$file" | cmp -s -- - "$file"
}

# impact_conf_write FILE VALUES_NAME
#   Writes the site settings file in one step (see impact_write_file_atomic),
#   mode 644, owned by root. The values are checked first: an invalid set is
#   never written.
#   Result: failure, with the causes in IMPACT_CONF_ERRORS, when the values
#   are invalid or the file cannot be written.
#   Example: impact_do "Write the settings file" impact_conf_write "$IMPACT_CONF_FILE" values
impact_conf_write() {
    local file="$1" text
    if ! impact_conf_validate "$2"; then
        for text in "${IMPACT_CONF_ERRORS[@]}"; do
            impact_error "$text"
        done
        return 1
    fi
    local content
    # "$( ... )" captures the printed text. It drops line ends at the very
    # end, so the "printf" below adds exactly one.
    content="$(impact_conf_render "$2" "$file")" || return 1
    if ((EUID == 0)); then
        printf '%s\n' "$content" | impact_write_file_atomic "$file" 644 root root
    else
        printf '%s\n' "$content" | impact_write_file_atomic "$file" 644
    fi
}

# =============================================================================
# The model file <MODEL_DIR>/<model>/model.conf
# =============================================================================

# impact_model_dir MODEL
#   Prints the administrator folder of a model: <MODEL_DIR>/<model>. The
#   site settings must be loaded and MODEL must be a valid model name.
#   Example: impact_model_dir Example-Model   prints /srv/impact/models/Example-Model
impact_model_dir() {
    impact_valid_model_name "$1" || return 1
    [[ -n "${IMPACT_CONF[MODEL_DIR]:-}" ]] || return 1
    printf '%s/%s\n' "${IMPACT_CONF[MODEL_DIR]}" "$1"
}

# impact_model_check_value KEY VALUE
#   Checks one value of a model file. Result as impact_conf_check_value.
#   STORAGE_ROOTS is compared with SHARED_ROOTS of the loaded site settings.
impact_model_check_value() {
    local key="$1" value="$2" entry
    local -a entries=() roots=()
    IMPACT_CHECK_REASON=''
    case "$key" in
        MODEL_CONF_VERSION)
            [[ "$value" == '1' ]] && return 0
            IMPACT_CHECK_REASON="this version of the commands understands format version 1 only"
            ;;
        REPO_URL)
            impact_valid_repo_url "$value" && return 0
            IMPACT_CHECK_REASON="expected the form git@github.com:<owner>/<repository>.git"
            ;;
        BRANCH)
            [[ -z "$value" ]] && return 0
            impact_valid_branch_name "$value" && return 0
            IMPACT_CHECK_REASON="expected nothing (the default branch of the repository) or a git branch name made of letters, digits and . _ / - only"
            ;;
        STORAGE_NAME)
            impact_valid_storage_name "$value" && return 0
            IMPACT_CHECK_REASON="expected a folder name: a letter or digit, then up to 39 letters, digits, _ . or -"
            ;;
        STORAGE_ROOTS)
            IMPACT_CHECK_REASON="expected one or more of the storage roots listed in SHARED_ROOTS of $IMPACT_CONF_FILE, separated by commas"
            impact_split_list "$value" entries
            ((${#entries[@]} >= 1)) || return 1
            impact_split_list "${IMPACT_CONF[SHARED_ROOTS]:-}" roots
            for entry in "${entries[@]}"; do
                impact_valid_abs_path "$entry" || return 1
                impact_in_list "$entry" "${roots[@]}" || return 1
            done
            IMPACT_CHECK_REASON=''
            return 0
            ;;
        *)
            IMPACT_CHECK_REASON="unknown key"
            ;;
    esac
    return 1
}

# impact_model_validate VALUES_NAME
#   Checks a complete set of model values. Result: success, or failure with
#   one text per problem in IMPACT_MODEL_ERRORS.
impact_model_validate() {
    local -n impact__model_values="$1"
    local key
    IMPACT_MODEL_ERRORS=()
    for key in "${IMPACT_MODEL_KEYS[@]}"; do
        if [[ ! -v impact__model_values[$key] ]]; then
            if ! impact_in_list "$key" "${IMPACT_MODEL_OPTIONAL_KEYS[@]}"; then
                IMPACT_MODEL_ERRORS+=("The required key $key is missing.")
            fi
            continue
        fi
        if ! impact_model_check_value "$key" "${impact__model_values[$key]}"; then
            IMPACT_MODEL_ERRORS+=("$key has the value '$(impact_display "${impact__model_values[$key]}")': $IMPACT_CHECK_REASON.")
        fi
    done
    ((${#IMPACT_MODEL_ERRORS[@]} == 0))
}

# impact_model_parse_file FILE
#   Reads and checks one model file. The site settings must be loaded first.
#   Result on success: IMPACT_MODEL holds every key (BRANCH may be empty).
#   Result on failure: exit status 1, IMPACT_MODEL is empty, causes in
#   IMPACT_MODEL_ERRORS. Unknown keys are named in IMPACT_MODEL_WARNINGS.
impact_model_parse_file() {
    local file="$1" key
    local -A parsed=()
    local -a order=() errors=()
    IMPACT_MODEL=()
    IMPACT_MODEL_ERRORS=()
    IMPACT_MODEL_WARNINGS=()
    if ! impact_kv_parse "$file" parsed order errors; then
        IMPACT_MODEL_ERRORS=("${errors[@]}")
        return 1
    fi
    for key in "${order[@]}"; do
        if ! impact_in_list "$key" "${IMPACT_MODEL_KEYS[@]}"; then
            IMPACT_MODEL_WARNINGS+=("The key $key is unknown and is ignored.")
            unset -v "parsed[$key]"
        fi
    done
    if ! impact_model_validate parsed; then
        return 1
    fi
    for key in "${IMPACT_MODEL_KEYS[@]}"; do
        IMPACT_MODEL[$key]="${parsed[$key]:-}"
    done
    return 0
}

# impact_model_load MODEL
#   Reads the model file of MODEL into IMPACT_MODEL. The site settings must
#   be loaded first.
#   Result: 0 on success; 1 when the name is invalid or the model does not
#   exist; 2 when the model file exists and is invalid or not safe to use.
#   The causes are in IMPACT_MODEL_ERRORS.
#   Example: impact_model_load Example-Model && echo "${IMPACT_MODEL[REPO_URL]}"
impact_model_load() {
    local model="$1" folder file
    IMPACT_MODEL=()
    IMPACT_MODEL_ERRORS=()
    IMPACT_MODEL_WARNINGS=()
    if ! impact_valid_model_name "$model"; then
        IMPACT_MODEL_ERRORS=("'$(impact_display "$model")' is no valid model name.")
        return 1
    fi
    folder="$(impact_model_dir "$model")" || {
        IMPACT_MODEL_ERRORS=("The site settings are not loaded.")
        return 2
    }
    file="$folder/model.conf"
    if [[ ! -e "$file" && ! -L "$file" ]]; then
        IMPACT_MODEL_ERRORS=("The model '$model' is not set up on this workstation ($file does not exist).")
        return 1
    fi
    if ! impact_file_is_trusted "$file"; then
        IMPACT_MODEL_ERRORS=("The model file is not safe to use: $IMPACT_CHECK_REASON")
        return 2
    fi
    impact_model_parse_file "$file" || return 2
}

# impact_require_model MODEL
#   Loads the model file or stops the command with exit code 1 after printing
#   every problem. The reason word for the IMPACT_RESULT line is
#   "unknown_model" or "model_invalid".
#   Example: impact_require_model "${IMPACT_ARGS[0]}"
impact_require_model() {
    local status=0 text
    impact_model_load "$1" || status=$?
    if ((status == 0)); then
        return 0
    fi
    for text in "${IMPACT_MODEL_ERRORS[@]}"; do
        impact_error "$text"
    done
    if ((status == 1)); then
        IMPACT_RESULT_REASON='unknown_model'
        impact_die "$IMPACT_EXIT_FAILED" "The model '$(impact_display "$1")' is not available on this workstation." \
            "Check the spelling. To add a model, the administrator runs impact-add-model. Contact: $(impact_contact_text)."
    fi
    IMPACT_RESULT_REASON='model_invalid'
    impact_die "$IMPACT_EXIT_FAILED" "The model file of '$(impact_display "$1")' is invalid." \
        "The administrator corrects it with impact-add-model. Contact: $(impact_contact_text)."
}

# impact__model_header
#   Internal: prints the comment block at the top of a new model file.
impact__model_header() {
    cat <<'END'
# IMPACT Docker GUI: settings of one model on this workstation
#
# Written by impact-add-model. Format: one KEY=value per line, no quotes.
# The file is read as text and is never executed.
END
}

# impact__model_help KEY
#   Internal: prints the comment lines that explain one key of a model file.
impact__model_help() {
    case "$1" in
        MODEL_CONF_VERSION)
            printf '%s\n' '# Format version of this file. Always 1.'
            ;;
        REPO_URL)
            printf '%s\n' '# Address of the model repository on GitHub, in the SSH form.'
            ;;
        BRANCH)
            printf '%s\n' '# Branch that new working copies start on. Empty means: the default' \
                '# branch of the repository.'
            ;;
        STORAGE_NAME)
            printf '%s\n' '# Folder name of this model below each storage root.'
            ;;
        STORAGE_ROOTS)
            printf '%s\n' '# Storage roots this model may use, separated by commas. Each one must' \
                '# be listed in SHARED_ROOTS of the site settings file.'
            ;;
        *) ;;
    esac
}

# impact_model_conf_render VALUES_NAME [EXISTING_FILE]
#   Prints the content of a model file for the given values; comments and
#   unknown lines of an existing file are kept. Nothing is written.
impact_model_conf_render() {
    impact__kv_render "${2:-}" "$1" IMPACT_MODEL_KEYS impact__model_help impact__model_header
}

# impact_model_conf_needs_write FILE VALUES_NAME
#   Result: success when writing the values would change FILE (or FILE does
#   not exist).
impact_model_conf_needs_write() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 0
    ! impact_model_conf_render "$2" "$file" | cmp -s -- - "$file"
}

# impact_model_conf_write FILE VALUES_NAME
#   Writes a model file in one step: mode 640, owner root, group SHARED_GROUP
#   (so members can read it and only root can change it). The values are
#   checked first; an invalid set is never written.
#   Example: impact_do "Write model.conf" impact_model_conf_write "$folder/model.conf" values
impact_model_conf_write() {
    local file="$1" text content
    if ! impact_model_validate "$2"; then
        for text in "${IMPACT_MODEL_ERRORS[@]}"; do
            impact_error "$text"
        done
        return 1
    fi
    content="$(impact_model_conf_render "$2" "$file")" || return 1
    if ((EUID == 0)); then
        printf '%s\n' "$content" | impact_write_file_atomic "$file" 640 root "${IMPACT_CONF[SHARED_GROUP]}"
    else
        printf '%s\n' "$content" | impact_write_file_atomic "$file" 640
    fi
}
