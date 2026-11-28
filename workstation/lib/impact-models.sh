#!/bin/bash
# =============================================================================
# impact-models.sh: shared functions for models, extras and working copies
#
# Purpose
#   The five commands that deal with model repositories load this file after
#   impact-common.sh:
#     impact-add-model      creates the model folder and the storage folders
#     impact-check-model    checks a model, its extras and the working copies
#     impact-get-repo       makes a person's working copy of a model
#     impact-give-repo      runs impact-get-repo for a person
#     impact-update-setup   copies docker_setup from GitHub into a copy
#   It holds the rules for "extras" (files that are not on GitHub and that
#   every new working copy receives), the way git talks to GitHub (strict
#   checking of GitHub's identity, the person's own key copy), and the
#   meaning of git's error messages (no access, network problem, and so on).
#
#   Terms used in this file
#     working copy   a folder with a model repository that git manages; the
#                    folder ".git" inside it holds git's own data
#     extras         files of the folder <MODEL_DIR>/<model>/extras, at the
#                    same relative path as they get in the working copy
#     key copy       the copy of a person's private SSH key in the home
#                    folder: ~/.ssh/id_ed25519_<GitHub name>
#     host key       the key by which a server proves its identity; GitHub's
#                    three keys are in /etc/impact/github_known_hosts
#
# Who runs it
#   Nobody runs this file directly. The commands load it with "source".
#
# Usage (inside a command, after impact-common.sh was loaded)
#   # shellcheck source=../lib/impact-models.sh
#   source "$IMPACT_LIB_DIR/impact-models.sh"
#   impact_extras_scan "$model_dir/extras"
#   impact_git_classify_error "$error_text"
#
# What it changes on the system
#   Loading the file changes nothing. Only impact_models_create_shared_dir
#   creates a folder; the commands call it through impact_do.
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
#   $'\t'  $'\r'  $'\n'   a text with a special character: tab, carriage return,
#                        new line (\xNN is the byte NN)
#   shopt -s nullglob    a file pattern (*.conf) without a match gives an empty
#                        list; "shopt -u" switches this off again
# Constructs beyond these are explained where they are first used.
# -----------------------------------------------------------------------------

# The line for the checking tool "shellcheck" must stand before the first
# command of the file to count for the whole file.
# shellcheck disable=SC2034
# Reason for SC2034 (variable appears unused): this file sets variables that
# the commands read after calling a function (for example
# IMPACT_EXTRAS_FILES). shellcheck checks one file at a time and cannot see
# those uses.

# This file is loaded once per script.
if [[ -n "${IMPACT_MODELS_LOADED:-}" ]]; then
    return 0
fi
IMPACT_MODELS_LOADED=1

# The library must be loaded first: this file uses its functions.
if [[ -z "${IMPACT_COMMON_LOADED:-}" ]]; then
    printf 'ERROR: impact-models.sh needs impact-common.sh, which must be loaded first.\n' >&2
    exit 1
fi

# Fixed values of this file.
readonly IMPACT_MODEL_STORAGE_MODE=2770        # new storage folders: group may write, others nothing
readonly IMPACT_MODEL_FOLDER_MODE=2750         # model folder and extras: group may read
readonly IMPACT_LARGE_FILE_MB=50               # impact-check-model lists extras above this size
readonly IMPACT_UPDATE_REF='refs/impact-update-setup'   # temporary name for a fetched state (one level, so no folder stays behind)
readonly IMPACT_EXCLUDE_MARK='# IMPACT extras: files from the workstation that are not on GitHub.'

# State that the functions below fill.
IMPACT_EXTRAS_FILES=()      # relative paths of the extra files
IMPACT_EXTRAS_DIRS=()       # relative paths of the extra folders
IMPACT_EXTRAS_PROBLEMS=()   # one text per entry that breaks the rules
IMPACT_GIT_ERROR_CODE=1     # exit code for the last classified git error
IMPACT_GIT_ERROR_REASON=''  # one-word reason for the result line
IMPACT_GIT_ERROR_CAUSE=''   # the cause in plain words
IMPACT_KEY_COPY_PROBLEM=''  # why a key copy cannot be used
IMPACT_MODELS_LOCK_FD=''    # open handle of the folder lock

# =============================================================================
# Storage folders of a model
# =============================================================================

# impact_models_storage_folders BASE
#   Prints the four folders that a model needs on one storage root, one per
#   line, parents first: BASE, BASE/outputs, BASE/inputs, BASE/inputs/synthpop.
#   BASE is <storage root>/<storage name>. Pure text work.
#   Example: impact_models_storage_folders /mnt/disk_a/shared/Example
impact_models_storage_folders() {
    printf '%s\n' "$1" "$1/outputs" "$1/inputs" "$1/inputs/synthpop"
}

# impact_models_roots_union EXISTING_TEXT NEW_ROOT...
#   Prints the comma-separated list of storage roots that results when the
#   new roots are added to the existing list: the existing entries first, in
#   their order, then each new root that is not yet listed. Nothing is ever
#   removed. Pure text work.
#   Example: impact_models_roots_union /mnt/disk_a/shared /mnt/disk_b/shared
#            prints /mnt/disk_a/shared,/mnt/disk_b/shared
impact_models_roots_union() {
    local existing="$1" root text=''
    shift
    local -a result=()
    impact_split_list "$existing" result
    for root in "$@"; do
        if ! impact_in_list "$root" "${result[@]}"; then
            result+=("$root")
        fi
    done
    for root in "${result[@]}"; do
        if [[ -z "$text" ]]; then
            text="$root"
        else
            text+=",$root"
        fi
    done
    printf '%s' "$text"
}

# impact_models_create_shared_dir PATH GROUP
#   Creates ONE new storage folder and gives it the shared rules: owner root,
#   group GROUP, mode 2770 (the "2" is the setgid bit: new entries inherit
#   the group), then impact_shared_apply_dir for the default access list.
#   Only this folder is touched; nothing below it exists yet.
#   Protection: the parent folder must be a real folder at exactly its own
#   resolved path (no symbolic link on the way), so the new folder cannot
#   land in another place. PATH itself must not exist yet.
#   Parameters: the full, resolved path of the new folder, and the group.
#   Result: success, or failure with an error line. Needs root rights.
#   Example: impact_do "Create ..." impact_models_create_shared_dir /mnt/disk_a/shared/Example impact
impact_models_create_shared_dir() {
    local path="$1" group="$2" parent real
    parent="$(dirname -- "$path")"
    real="$(realpath -e -- "$parent" 2>/dev/null)" || real=''
    if [[ -L "$parent" || ! -d "$parent" || "$real" != "$parent" ]]; then
        impact_error "$parent is no real folder at this path (a symbolic link is on the way, or it is missing)."
        return 1
    fi
    if [[ -e "$path" || -L "$path" ]]; then
        impact_error "$path exists already; it was left as it is."
        return 1
    fi
    # mkdir never follows a symbolic link at the new name itself: it fails
    # when anything exists there.
    mkdir -m "$IMPACT_MODEL_STORAGE_MODE" -- "$path" || return 1
    chown -- "root:$group" "$path" || return 1
    # chown can clear the setgid bit, so the mode is set again afterwards.
    chmod -- "$IMPACT_MODEL_STORAGE_MODE" "$path" || return 1
    impact_shared_apply_dir "$path" "$group"
}

# =============================================================================
# Extras: files of the workstation that every new working copy receives
# =============================================================================

# impact_extras_valid_path RELATIVE_PATH
#   The name rule for an extra. Every part between two "/" must
#     - consist of letters, digits and . _ + @ ( ) , = - with spaces only
#       between other characters (no space at the start or end of a part),
#     - not start with "-" (it could be read as an option),
#     - not be "." or "..", and not start with ".git" in any spelling
#       (".git" is git's own folder; ".gitignore", ".gitattributes" and
#       ".gitmodules" change how git treats other files),
#     - be at most 255 characters long; the whole path at most 1024.
#   Why so strict: the path is written into git's ignore list and handed to
#   git commands. With these characters it means exactly itself there, with
#   no pattern or special meaning.
#   Result: success or failure. Pure text work.
#   Example: impact_extras_valid_path "inputs/tables/population 2020.csv"   succeeds
impact_extras_valid_path() {
    local path="$1" part lower
    local -a parts=()
    # The patterns are kept in variables: written directly after "=~", the
    # space inside the brackets would need a backslash, which bash may hand
    # on to the pattern.
    local all_characters='^[A-Za-z0-9._+@(),=/ -]+$'
    local one_part='^[A-Za-z0-9._+@(),=]([A-Za-z0-9._+@(),= -]*[A-Za-z0-9._+@(),=-])?$'
    [[ -n "$path" && ${#path} -le 1024 ]] || return 1
    # This first check also refuses line breaks, which "read" below would
    # otherwise cut off unseen.
    [[ "$path" =~ $all_characters ]] || return 1
    [[ "$path" != /* && "$path" != */ && "$path" != *//* ]] || return 1
    # "IFS=/ read -r -a parts" splits the text at each "/" into a list.
    IFS=/ read -r -a parts <<<"$path"
    for part in "${parts[@]}"; do
        ((${#part} >= 1 && ${#part} <= 255)) || return 1
        [[ "$part" =~ $one_part ]] || return 1
        [[ "$part" != '.' && "$part" != '..' ]] || return 1
        lower="$(impact_lower "$part")"
        [[ "$lower" != .git* ]] || return 1
    done
    return 0
}

# impact_extras_scan FOLDER
#   Lists the content of an extras folder and checks every entry. Symbolic
#   links are never followed. Allowed are plain files and folders whose paths
#   pass impact_extras_valid_path, and that the running account can read.
#   Result in three lists (relative paths, sorted):
#     IMPACT_EXTRAS_FILES     the plain files
#     IMPACT_EXTRAS_DIRS      the folders
#     IMPACT_EXTRAS_PROBLEMS  one text per entry that breaks the rules
#   A missing FOLDER gives three empty lists (a model without extras).
#   Returns success when IMPACT_EXTRAS_PROBLEMS is empty.
#   Example: impact_extras_scan /srv/impact/models/Example-Model/extras
impact_extras_scan() {
    local folder="$1" relative full status=0
    IMPACT_EXTRAS_FILES=()
    IMPACT_EXTRAS_DIRS=()
    IMPACT_EXTRAS_PROBLEMS=()
    if [[ ! -e "$folder" && ! -L "$folder" ]]; then
        return 0
    fi
    if [[ -L "$folder" || ! -d "$folder" ]]; then
        IMPACT_EXTRAS_PROBLEMS+=("$folder is no real folder (a symbolic link or a file).")
        return 1
    fi
    if [[ ! -r "$folder" || ! -x "$folder" ]]; then
        IMPACT_EXTRAS_PROBLEMS+=("$folder cannot be read by the account $(id -un).")
        return 1
    fi
    local -a entries=()
    # find -P never follows symbolic links; -mindepth 1 leaves out the folder
    # itself; "-printf '%P\0'" prints each path relative to the folder, ended
    # by a zero byte, so that any character in a name stays intact.
    # "mapfile -d ''" reads such zero-ended texts into a list, and "< <(...)"
    # (process substitution) feeds it the output of the command.
    mapfile -d '' -t entries < <(find -P "$folder" -mindepth 1 -printf '%P\0' 2>/dev/null | LC_ALL=C sort -z)
    # "find" reports a folder it could not read with a non-zero exit code. The
    # pipeline above hides that code, so it runs once more just for it.
    find -P "$folder" -mindepth 1 -printf '' 2>/dev/null || status=1
    if ((status != 0)); then
        IMPACT_EXTRAS_PROBLEMS+=("Some parts of $folder cannot be read by the account $(id -un).")
    fi
    for relative in "${entries[@]}"; do
        full="$folder/$relative"
        if ! impact_extras_valid_path "$relative"; then
            IMPACT_EXTRAS_PROBLEMS+=("'$(impact_display "$relative")' has a name that is not allowed for extras (letters, digits, spaces inside a name and . _ + @ ( ) , = - only; no part named .git...).")
            continue
        fi
        if [[ -L "$full" ]]; then
            IMPACT_EXTRAS_PROBLEMS+=("'$relative' is a symbolic link. Extras may hold plain files and folders only.")
        elif [[ -d "$full" ]]; then
            if [[ ! -r "$full" || ! -x "$full" ]]; then
                IMPACT_EXTRAS_PROBLEMS+=("The folder '$relative' cannot be read by the account $(id -un).")
            else
                IMPACT_EXTRAS_DIRS+=("$relative")
            fi
        elif [[ -f "$full" ]]; then
            if [[ ! -r "$full" ]]; then
                IMPACT_EXTRAS_PROBLEMS+=("The file '$relative' cannot be read by the account $(id -un).")
            else
                IMPACT_EXTRAS_FILES+=("$relative")
            fi
        else
            IMPACT_EXTRAS_PROBLEMS+=("'$relative' is neither a plain file nor a folder.")
        fi
    done
    ((${#IMPACT_EXTRAS_PROBLEMS[@]} == 0))
}

# impact_extras_exclude_lines FILE...
#   Prints the block that goes into the ignore list of a working copy
#   (.git/info/exclude): one comment line, then one line per extra file.
#   Each line starts with "/", which ties it to exactly that path from the
#   top of the working copy (a file of the same name in another folder is
#   not affected). The paths must have passed impact_extras_valid_path, so
#   none of them contains a character with a special meaning in that list.
#   Pure text work.
#   Example: impact_extras_exclude_lines inputs/tables/a.csv
#            prints the comment line and /inputs/tables/a.csv
impact_extras_exclude_lines() {
    local path
    printf '%s\n' "$IMPACT_EXCLUDE_MARK"
    for path in "$@"; do
        printf '/%s\n' "$path"
    done
}

# impact_extras_large_files FOLDER
#   Prints the extra files larger than IMPACT_LARGE_FILE_MB megabytes, one
#   per line as "<size in MB> <relative path>". Symbolic links are not
#   followed.
impact_extras_large_files() {
    local folder="$1" size path
    [[ -d "$folder" && ! -L "$folder" ]] || return 0
    # "-size +50M" means larger than 50 mebibytes; %s is the size in bytes.
    while IFS= read -r -d '' size && IFS= read -r -d '' path; do
        printf '%s %s\n' "$((size / 1048576))" "$(impact_display "$path")"
    done < <(find -P "$folder" -type f -size "+${IMPACT_LARGE_FILE_MB}M" -printf '%s\0%P\0' 2>/dev/null)
}

# =============================================================================
# git and GitHub
# =============================================================================

# impact_git_clean_env
#   Removes environment variables that would change what git does: every
#   variable that starts with GIT_ (for example GIT_DIR, which points git to
#   another repository, or GIT_SSH_COMMAND), the programs that answer
#   password questions, and the connection to an SSH agent. The commands set
#   the few values they need themselves.
impact_git_clean_env() {
    local name
    # "compgen -A export" lists the names of all exported variables.
    while IFS= read -r name; do
        if [[ "$name" == GIT_* ]]; then
            unset -v "$name"
        fi
    done < <(compgen -A export)
    unset -v SSH_ASKPASS SSH_ASKPASS_REQUIRE SSH_AUTH_SOCK
}

# impact_git_ssh_command KEY_FILE
#   Prints the command line with which git starts ssh for GitHub. Its parts:
#     -F none                     ignore all ssh settings files, so only the
#                                 options below count
#     BatchMode=yes               never ask a question on the terminal
#     IdentitiesOnly=yes, -i      use this one key and no other
#     IdentityAgent=none          no key from an SSH agent
#     StrictHostKeyChecking=yes   connect only when the server shows a key of
#                                 the known-hosts file
#     UserKnownHostsFile          the file with GitHub's three keys
#     GlobalKnownHostsFile        no second file
#     UpdateHostKeys=no           never change that file
#     ConnectTimeout, ServerAlive...  give up on a dead connection
#   KEY_FILE must be a clean absolute path (impact_valid_abs_path); it is
#   put in single quotes because git hands this line to a shell.
#   Example: GIT_SSH_COMMAND="$(impact_git_ssh_command /home/alice/.ssh/id_ed25519_alice-example)"
impact_git_ssh_command() {
    local key="$1"
    impact_valid_abs_path "$key" || return 1
    printf "ssh -F none -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -i '%s' -o StrictHostKeyChecking=yes -o 'UserKnownHostsFile=%s' -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o CheckHostIP=no -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4" \
        "$key" "$IMPACT_KNOWN_HOSTS_FILE"
}

# impact_git ARGUMENTS...
#   Runs git with settings that make it predictable for these commands:
#     core.fsmonitor=false  no helper program that watches files
#     gc.auto=0, maintenance.auto=false   no clean-up work in the background
#   and with GIT_TERMINAL_PROMPT=0, so git never waits for a typed answer.
#   The only path the commands hand to git as a "pathspec" (a path pattern)
#   is the fixed name docker_setup; extra files reach git through
#   "check-ignore --stdin", which reads plain paths.
#   Result: the exit code of git.
#   Example: impact_git -C "$copy" status --short
impact_git() {
    GIT_TERMINAL_PROMPT=0 git -c core.fsmonitor=false -c gc.auto=0 \
        -c maintenance.auto=false "$@"
}

# impact_git_classify_error TEXT
#   Reads the error text of a failed git clone or fetch and decides what it
#   means. The texts come from git, ssh and GitHub; they are in English
#   because the commands run with LC_ALL=C.
#   Result in three variables:
#     IMPACT_GIT_ERROR_CODE    1 failed, 5 no access, 6 network problem
#     IMPACT_GIT_ERROR_REASON  one word for the result line: host_key,
#                              key_refused, key_unusable, no_access,
#                              network, branch_missing or git_failed
#     IMPACT_GIT_ERROR_CAUSE   the cause in plain words
#   The order of the checks matters: a refused key or an unknown repository
#   is often followed by "The remote end hung up", which alone would look
#   like a network problem.
#   Example: impact_git_classify_error "$(cat "$error_file")"
impact_git_classify_error() {
    local text="$1"
    IMPACT_GIT_ERROR_CODE=1
    IMPACT_GIT_ERROR_REASON='git_failed'
    IMPACT_GIT_ERROR_CAUSE='git could not copy the repository (see the messages above).'
    case "$text" in
        *'Host key verification failed'* | *'REMOTE HOST IDENTIFICATION HAS CHANGED'* | \
            *'host key for'*'has changed'* | *'No '*' host key is known for'*)
            IMPACT_GIT_ERROR_REASON='host_key'
            IMPACT_GIT_ERROR_CAUSE="The server did not show one of GitHub's published keys (file $IMPACT_KNOWN_HOSTS_FILE). The connection was refused for safety: it may not lead to GitHub."
            ;;
        *'Permission denied (publickey'*)
            IMPACT_GIT_ERROR_CODE=5
            IMPACT_GIT_ERROR_REASON='key_refused'
            IMPACT_GIT_ERROR_CAUSE='GitHub refused the key copy: this key is not registered on the GitHub account.'
            ;;
        *'UNPROTECTED PRIVATE KEY FILE'* | *'bad permissions'* | *'Load key'*'invalid format'* | \
            *'Load key'*'error in libcrypto'* | *'no such identity'* | *'Load key'*'No such file'*)
            IMPACT_GIT_ERROR_REASON='key_unusable'
            IMPACT_GIT_ERROR_CAUSE='ssh could not use the key copy (damaged, unreadable or readable by other accounts).'
            ;;
        *'Repository not found'* | *'does not appear to be a git repository'* | \
            *'could not read Username'* | *'Authentication failed'* | \
            *'The requested URL returned error: 401'* | *'The requested URL returned error: 403'* | \
            *'The requested URL returned error: 404'*)
            IMPACT_GIT_ERROR_CODE=5
            IMPACT_GIT_ERROR_REASON='no_access'
            IMPACT_GIT_ERROR_CAUSE='GitHub does not give this account access to the repository (it does not exist, or it is private and the GitHub account has no access).'
            ;;
        *'Remote branch'*'not found'* | *"couldn't find remote ref"*)
            IMPACT_GIT_ERROR_REASON='branch_missing'
            IMPACT_GIT_ERROR_CAUSE='The branch named in the model settings does not exist on GitHub.'
            ;;
        *'Could not resolve host'* | *'Temporary failure in name resolution'* | \
            *'Connection timed out'* | *'Operation timed out'* | *'timed out after'* | \
            *'Connection refused'* | *'Network is unreachable'* | *'No route to host'* | \
            *'Failed to connect'* | *'Connection reset'* | *'Connection closed by'* | \
            *'kex_exchange_identification'* | *'Broken pipe'* | *'early EOF'* | \
            *'The remote end hung up unexpectedly'* | *'RPC failed'* | *'unexpected disconnect'* | \
            *'gnutls_handshake'* | *'SSL'* | *'Timeout, server'*)
            IMPACT_GIT_ERROR_CODE=6
            IMPACT_GIT_ERROR_REASON='network'
            IMPACT_GIT_ERROR_CAUSE='The workstation could not reach GitHub, or the connection broke off.'
            ;;
        *) ;;
    esac
}

# impact_git_same_repo ADDRESS_A ADDRESS_B
#   Result: success when both texts are GitHub addresses (SSH or HTTPS form,
#   see impact_parse_github_address) of the same repository. GitHub ignores
#   upper and lower case in owner and repository names, so this does too.
#   Example: impact_git_same_repo git@github.com:o/r.git https://github.com/o/r
impact_git_same_repo() {
    local first
    impact_parse_github_address "$1" || return 1
    first="$(impact_lower "$IMPACT_GH_SSH_URL")"
    impact_parse_github_address "$2" || return 1
    [[ "$first" == "$(impact_lower "$IMPACT_GH_SSH_URL")" ]]
}

# =============================================================================
# The person's key copy
# =============================================================================

# impact_key_copy_names HOME
#   Prints the GitHub names (lower case) of all key copies in HOME/.ssh: the
#   files named id_ed25519_<name> without ".pub" whose <name> is a valid
#   GitHub name. Symbolic links count as well here; impact_key_copy_usable
#   refuses them later with a clear message.
#   Example: impact_key_copy_names /home/alice   prints alice-example
impact_key_copy_names() {
    local file name
    # "shopt -s nullglob" (inside "( ... )", so only for this copy of the
    # script) makes a pattern without any match expand to nothing.
    (
        shopt -s nullglob
        for file in "$1"/.ssh/id_ed25519_*; do
            name="${file##*/id_ed25519_}"
            if [[ "$name" == *.pub ]] || ! impact_valid_github_name "$name"; then
                continue
            fi
            impact_lower "$name"
            printf '\n'
        done | LC_ALL=C sort -u
    )
}

# impact_key_copy_usable PATH
#   Result: success when PATH is a private key copy that ssh will accept: a
#   plain file (no symbolic link), owned by the running account, and
#   readable by nobody else (ssh refuses a key file that others can read).
#   On failure IMPACT_KEY_COPY_PROBLEM holds the reason.
impact_key_copy_usable() {
    local path="$1" mode
    IMPACT_KEY_COPY_PROBLEM=''
    if [[ -L "$path" ]]; then
        IMPACT_KEY_COPY_PROBLEM="$path is a symbolic link; a plain file is expected."
        return 1
    fi
    if [[ ! -e "$path" ]]; then
        IMPACT_KEY_COPY_PROBLEM="$path does not exist."
        return 1
    fi
    # "-O" is true when the file belongs to the running account.
    if [[ ! -f "$path" || ! -O "$path" || ! -r "$path" ]]; then
        IMPACT_KEY_COPY_PROBLEM="$path is no readable plain file of the account $(id -un)."
        return 1
    fi
    mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || mode=''
    if ! [[ "$mode" =~ ^[0-7]+$ ]] || (((8#$mode & 8#077) != 0)); then
        IMPACT_KEY_COPY_PROBLEM="$path (mode ${mode:-unknown}) can be read by other accounts, and ssh refuses such a key. Fix it with: chmod 600 $path"
        return 1
    fi
    return 0
}

# =============================================================================
# A lock for the repository folder of a person
# =============================================================================

# impact_models_lock_dir FOLDER
#   Makes sure that only one impact-get-repo or impact-update-setup works in
#   the repository folder of a person at a time, for example when a button in
#   the GUI was pressed twice. The lock is taken on the folder itself, so no
#   lock file is left behind; the system releases it when the command ends.
#   Result: success when the lock was taken; failure when another command
#   holds it or the folder cannot be opened.
impact_models_lock_dir() {
    # "exec {NAME}<path" opens the path for reading and stores the number of
    # the new handle in the variable NAME.
    if ! { exec {IMPACT_MODELS_LOCK_FD}<"$1"; } 2>/dev/null; then
        IMPACT_MODELS_LOCK_FD=''
        return 1
    fi
    # flock -n takes the lock on the open folder, or fails at once when
    # another process holds it.
    flock -n "$IMPACT_MODELS_LOCK_FD"
}
