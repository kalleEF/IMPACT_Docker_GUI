#!/bin/bash
# =============================================================================
# install.sh: install the IMPACT workstation commands
#
# Purpose
#   Copies the commands from this unpacked folder to /opt/impact and makes
#   them available under their names (for example "sudo impact-check").
#
# Who runs it
#   The administrator of the workstation, with sudo, from the unpacked folder.
#
# Usage
#   sudo ./install.sh [--dry-run]
#
# Examples
#   sudo ./install.sh --dry-run     show every step, change nothing
#   sudo ./install.sh               install, or update an older installation
#   ./install.sh --help             show this text
#
# What it changes on the system
#   /opt/impact/bin, /opt/impact/lib, /opt/impact/etc   the commands and their
#       shared files (owner root; commands mode 755, other files mode 644)
#   /opt/impact/VERSION, /opt/impact/uninstall.sh
#   /usr/local/bin/impact-*    symbolic links (pointers) to /opt/impact/bin,
#       so that the commands are found by name
#   /opt/impact/admin          folder for logs and saved states, readable by
#       root only (mode 700)
#   It checks that the tools the commands need are present. For missing tools
#   it prints the "apt-get install" line and stops. It installs no packages.
#   It creates no accounts, no groups and no settings; that is the task of
#   impact-workstation-setup.
#
# How to undo
#   sudo /opt/impact/uninstall.sh
#
# Exit codes
#   0 done or nothing to do; 1 a check failed; 2 wrong usage;
#   4 a file of another origin is in the way.
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

# "set -e" stops the script at the first command that fails, "-u" stops it
# when a variable is read that was never set, and "-o pipefail" makes a chain
# of commands joined with "|" fail when any part of it fails.
set -euo pipefail

# The folder this script lies in. BASH_SOURCE[0] is the path of this file;
# "readlink -f" turns it into a full path with all symbolic links resolved.
IMPACT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SOURCE_DIR="$(dirname -- "$IMPACT_SELF")"

if [[ ! -r "$SOURCE_DIR/lib/impact-common.sh" ]]; then
    printf 'ERROR: %s/lib/impact-common.sh is missing. Unpack the complete archive and run install.sh from the unpacked folder.\n' "$SOURCE_DIR" >&2
    exit 1
fi
# "source" reads the shared functions into this script.
# The two comment lines below tell the checking tool "shellcheck" where the
# loaded file is.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/impact-common.sh
source "$SOURCE_DIR/lib/impact-common.sh"
impact_init "$IMPACT_SELF"

impact_parse_args 'dry-run' '' '' "$@"
impact_require_arg_count 0 0
impact_require_root
impact_log_enable "$@"

# The tools the commands need: the list IMPACT_NEEDED_TOOLS of the library.
# docker is checked separately, because it does not come from Ubuntu's own
# package source.
readonly -a NEEDED_TOOLS=("${IMPACT_NEEDED_TOOLS[@]}")

# Lists that the checks fill and the steps use.
COMMAND_FILES=()   # full paths of the commands in the unpacked folder
LIB_FILES=()       # the same for the library files
ETC_FILES=()       # and for the files of the etc folder
STALE_LINKS=()     # links of an older installation whose command is gone
NEW_VERSION=''

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

# collect_files FOLDER PATTERN ARRAY_NAME
#   Fills the array ARRAY_NAME with the plain files in FOLDER whose names
#   match PATTERN, sorted by name.
collect_files() {
    local folder="$1" pattern="$2" file
    # "local -n" gives this function a second name for the caller's array.
    local -n collected="$3"
    collected=()
    # "nullglob" makes a pattern without any match expand to nothing; without
    # it bash would keep the pattern itself as a word.
    shopt -s nullglob
    for file in "$folder"/$pattern; do
        if [[ -f "$file" && ! -L "$file" ]]; then
            collected+=("$file")
        fi
    done
    shopt -u nullglob
}

# check_source
#   Stops unless the unpacked folder is complete and its scripts are free of
#   syntax errors. Protects against a damaged or half-copied archive.
check_source() {
    local file first_line
    if [[ "$SOURCE_DIR" == "$IMPACT_INSTALL_DIR" || "$SOURCE_DIR" == "$IMPACT_INSTALL_DIR"/* ]]; then
        impact_die "$IMPACT_EXIT_USAGE" "install.sh was started inside $IMPACT_INSTALL_DIR, the place it installs to." \
            "Unpack the archive in another folder, for example your home folder, and run install.sh there."
    fi
    collect_files "$SOURCE_DIR/bin" 'impact-*' COMMAND_FILES
    collect_files "$SOURCE_DIR/lib" 'impact-*.sh' LIB_FILES
    collect_files "$SOURCE_DIR/etc" '*' ETC_FILES
    if ((${#COMMAND_FILES[@]} == 0)); then
        impact_die "$IMPACT_EXIT_FAILED" "No commands were found in $SOURCE_DIR/bin." "Unpack the complete archive again."
    fi
    for file in "$SOURCE_DIR/VERSION" "$SOURCE_DIR/uninstall.sh" "$SOURCE_DIR/etc/github_known_hosts" \
        "$SOURCE_DIR/etc/impact.conf.example" "$SOURCE_DIR/lib/impact-settings.sh" \
        "$SOURCE_DIR/lib/impact-accounts.sh" "$SOURCE_DIR/lib/impact-storage.sh" \
        "$SOURCE_DIR/lib/impact-ssh.sh" "$SOURCE_DIR/lib/impact-docker.sh"; do
        if [[ ! -f "$file" || -L "$file" ]]; then
            impact_die "$IMPACT_EXIT_FAILED" "The file $file is missing from the unpacked folder." "Unpack the complete archive again."
        fi
    done
    IFS= read -r NEW_VERSION <"$SOURCE_DIR/VERSION" || true
    if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        impact_die "$IMPACT_EXIT_FAILED" "The file VERSION does not hold a version such as 2.1.0." "Unpack the complete archive again."
    fi
    for file in "${COMMAND_FILES[@]}" "$SOURCE_DIR/uninstall.sh"; do
        if ! [[ "$(basename -- "$file")" =~ ^[a-z][a-z0-9.-]*$ ]]; then
            impact_die "$IMPACT_EXIT_FAILED" "Unexpected file name in the unpacked folder: $(impact_display "$file")" "Unpack the complete archive again."
        fi
        IFS= read -r first_line <"$file" || true
        if [[ "$first_line" != '#!/bin/bash' ]]; then
            impact_die "$IMPACT_EXIT_FAILED" "$file does not start with the line #!/bin/bash." "Unpack the complete archive again."
        fi
    done
    for file in "${COMMAND_FILES[@]}" "${LIB_FILES[@]}" "$SOURCE_DIR/uninstall.sh"; do
        # "bash -n" reads a script and reports syntax errors; it runs nothing.
        if ! bash -n -- "$file" 2>/dev/null; then
            impact_die "$IMPACT_EXIT_FAILED" "$file contains a syntax error; the archive seems to be damaged." "Unpack the complete archive again."
        fi
    done
    impact_ok "The unpacked folder is complete: version $NEW_VERSION, number of commands: ${#COMMAND_FILES[@]}."
}

# check_tools
#   Stops with the apt-get line when a needed tool is missing. A missing
#   Docker gives a warning only: impact-workstation-setup checks Docker in
#   detail.
check_tools() {
    local -a missing=()
    mapfile -t missing < <(impact_missing_tools "${NEEDED_TOOLS[@]}" || true)
    if ((${#missing[@]} > 0)); then
        impact_error "These tools are missing on this machine: ${missing[*]}"
        impact_install_hint "${missing[@]}"
        impact_die "$IMPACT_EXIT_FAILED" "The commands cannot work without these tools. Nothing was installed." \
            "Run the apt-get line above, then run install.sh again."
    fi
    impact_ok "All needed tools are present."
    if ! impact_docker_installed; then
        impact_warn "Docker is not installed. The commands can be installed, and impact-workstation-setup will stop until Docker is there."
        impact_install_hint docker
    fi
}

# check_target
#   Stops when something of another origin is in the way: a symbolic link or
#   a plain file where a folder of the installation belongs, or a file in
#   /usr/local/bin with the name of a command. Fills STALE_LINKS.
check_target() {
    local item name link target
    for item in "$IMPACT_INSTALL_DIR" "$IMPACT_INSTALL_DIR/bin" "$IMPACT_INSTALL_DIR/lib" \
        "$IMPACT_INSTALL_DIR/etc" "$IMPACT_ADMIN_DIR"; do
        if [[ -L "$item" || (-e "$item" && ! -d "$item") ]]; then
            impact_die "$IMPACT_EXIT_CONFLICT" "$item exists and is no real folder." \
                "Look at it (ls -l $item) and move it away, then run install.sh again."
        fi
    done
    for item in "${COMMAND_FILES[@]}"; do
        name="$(basename -- "$item")"
        link="$IMPACT_LINK_DIR/$name"
        if [[ -L "$link" ]]; then
            target="$(readlink -- "$link")"
            if [[ "$target" != "$IMPACT_BIN_DIR"/* ]]; then
                impact_die "$IMPACT_EXIT_CONFLICT" "$link is a link to $target, which is no IMPACT command." \
                    "Move it away, then run install.sh again."
            fi
        elif [[ -e "$link" ]]; then
            impact_die "$IMPACT_EXIT_CONFLICT" "$link exists and is no link of an IMPACT installation." \
                "Move it away, then run install.sh again."
        fi
    done
    STALE_LINKS=()
    shopt -s nullglob
    for link in "$IMPACT_LINK_DIR"/impact-*; do
        if [[ -L "$link" ]]; then
            target="$(readlink -- "$link")"
            name="$(basename -- "$link")"
            if [[ "$target" == "$IMPACT_BIN_DIR"/* && ! -f "$SOURCE_DIR/bin/$name" ]]; then
                STALE_LINKS+=("$link")
            fi
        fi
    done
    shopt -u nullglob
    impact_ok "Nothing of another origin is in the way."
}

# tree_is_current SUBFOLDER MODE FILE...
#   Result: success when /opt/impact/SUBFOLDER holds exactly the given files,
#   with the same content, mode MODE and owner root.
tree_is_current() {
    local folder="$IMPACT_INSTALL_DIR/$1" mode="$2" file count
    shift 2
    impact_dir_is "$folder" 755 root root || return 1
    for file in "$@"; do
        impact_file_is "$folder/$(basename -- "$file")" "$mode" root root || return 1
        cmp -s -- "$file" "$folder/$(basename -- "$file")" || return 1
    done
    # Count the entries of the installed folder: an extra entry is a leftover.
    count="$(find "$folder" -mindepth 1 | wc -l)"
    [[ "$count" == "$#" ]]
}

# install_tree SUBFOLDER MODE FILE...
#   Replaces /opt/impact/SUBFOLDER by a folder that holds exactly the given
#   files. The new folder is prepared next to the old one and then swapped
#   in, so a command that is started at the same moment finds a complete
#   folder, the old one or the new one.
install_tree() {
    local name="$1" mode="$2" file
    local target="$IMPACT_INSTALL_DIR/$1"
    local staging="$IMPACT_INSTALL_DIR/.new-$1" previous="$IMPACT_INSTALL_DIR/.old-$1"
    shift 2
    rm -rf -- "$staging" "$previous" || return 1
    # "install" copies files and sets owner (-o), group (-g) and mode (-m) in
    # one go; with -d it creates a folder.
    install -d -m 755 -o root -g root -- "$staging" || return 1
    for file in "$@"; do
        install -m "$mode" -o root -g root -- "$file" "$staging/" || return 1
    done
    if [[ -d "$target" ]]; then
        mv -T -- "$target" "$previous" || return 1
    fi
    if ! mv -T -- "$staging" "$target"; then
        # Put the old folder back when the new one cannot be moved in place.
        if [[ -d "$previous" ]]; then
            mv -T -- "$previous" "$target"
        fi
        return 1
    fi
    rm -rf -- "$previous"
}

# install_single SOURCE TARGET MODE
#   Copies one file to TARGET with the given mode, owner root.
install_single() {
    install -m "$3" -o root -g root -T -- "$1" "$2"
}

# links_needed ARRAY_NAME
#   Fills ARRAY_NAME with the names of the commands whose link in
#   /usr/local/bin is missing or points to the wrong place.
links_needed() {
    local -n needed="$1"
    local file name
    needed=()
    for file in "${COMMAND_FILES[@]}"; do
        name="$(basename -- "$file")"
        if [[ ! -L "$IMPACT_LINK_DIR/$name" || "$(readlink -- "$IMPACT_LINK_DIR/$name")" != "$IMPACT_BIN_DIR/$name" ]]; then
            needed+=("$name")
        fi
    done
}

# make_links NAME...
#   Creates the links /usr/local/bin/NAME to /opt/impact/bin/NAME.
make_links() {
    local name
    install -d -m 755 -o root -g root -- "$IMPACT_LINK_DIR" || return 1
    for name in "$@"; do
        # ln -s creates a symbolic link; -f replaces an existing link; -T
        # treats the last argument as the link itself in every case.
        ln -s -f -T -- "$IMPACT_BIN_DIR/$name" "$IMPACT_LINK_DIR/$name" || return 1
    done
}

# remove_links LINK...
#   Removes the given links.
remove_links() {
    rm -f -- "$@"
}

# -----------------------------------------------------------------------------
# The steps
# -----------------------------------------------------------------------------

impact_step "Check the unpacked folder, the tools and the target"
check_source
check_tools
check_target
INSTALLED_VERSION=''
if [[ -r "$IMPACT_INSTALL_DIR/VERSION" ]]; then
    IFS= read -r INSTALLED_VERSION <"$IMPACT_INSTALL_DIR/VERSION" || true
    impact_info "Installed at the moment: version $(impact_display "$INSTALLED_VERSION"). This folder holds version $NEW_VERSION."
    if impact_version_ge "$INSTALLED_VERSION" "$NEW_VERSION" && [[ "$INSTALLED_VERSION" != "$NEW_VERSION" ]]; then
        impact_warn "The installed version is newer than the one in this folder. Continuing installs the older version."
    fi
fi

impact_step "Install the commands into $IMPACT_INSTALL_DIR"
if impact_dir_is "$IMPACT_INSTALL_DIR" 755 root root; then
    impact_ok "The folder $IMPACT_INSTALL_DIR exists."
else
    impact_do "Create the folder $IMPACT_INSTALL_DIR (owner root, mode 755)" \
        impact_make_dir "$IMPACT_INSTALL_DIR" 755 root root
fi
if tree_is_current bin 755 "${COMMAND_FILES[@]}"; then
    impact_ok "The commands in $IMPACT_BIN_DIR are up to date (number of commands: ${#COMMAND_FILES[@]})."
else
    impact_do "Install the commands into $IMPACT_BIN_DIR (number of commands: ${#COMMAND_FILES[@]})" install_tree bin 755 "${COMMAND_FILES[@]}"
fi
if tree_is_current lib 644 "${LIB_FILES[@]}"; then
    impact_ok "The shared files in $IMPACT_INSTALL_DIR/lib are up to date."
else
    impact_do "Install the shared files into $IMPACT_INSTALL_DIR/lib" install_tree lib 644 "${LIB_FILES[@]}"
fi
if tree_is_current etc 644 "${ETC_FILES[@]}"; then
    impact_ok "The files in $IMPACT_INSTALL_DIR/etc are up to date."
else
    impact_do "Install the settings example and GitHub's host keys into $IMPACT_INSTALL_DIR/etc" \
        install_tree etc 644 "${ETC_FILES[@]}"
fi
if impact_file_is "$IMPACT_INSTALL_DIR/uninstall.sh" 755 root root &&
    cmp -s -- "$SOURCE_DIR/uninstall.sh" "$IMPACT_INSTALL_DIR/uninstall.sh"; then
    impact_ok "$IMPACT_INSTALL_DIR/uninstall.sh is up to date."
else
    impact_do "Install $IMPACT_INSTALL_DIR/uninstall.sh" \
        install_single "$SOURCE_DIR/uninstall.sh" "$IMPACT_INSTALL_DIR/uninstall.sh" 755
fi
if impact_file_is "$IMPACT_INSTALL_DIR/VERSION" 644 root root &&
    cmp -s -- "$SOURCE_DIR/VERSION" "$IMPACT_INSTALL_DIR/VERSION"; then
    impact_ok "$IMPACT_INSTALL_DIR/VERSION says $NEW_VERSION."
else
    impact_do "Write $IMPACT_INSTALL_DIR/VERSION ($NEW_VERSION)" \
        install_single "$SOURCE_DIR/VERSION" "$IMPACT_INSTALL_DIR/VERSION" 644
fi

impact_step "Make the commands available by name"
LINK_NAMES=()
links_needed LINK_NAMES
if ((${#LINK_NAMES[@]} == 0)); then
    impact_ok "All links in $IMPACT_LINK_DIR exist."
else
    impact_do "Create the links in $IMPACT_LINK_DIR for: ${LINK_NAMES[*]}" make_links "${LINK_NAMES[@]}"
fi
if ((${#STALE_LINKS[@]} > 0)); then
    impact_do "Remove links to commands that no longer exist: ${STALE_LINKS[*]}" remove_links "${STALE_LINKS[@]}"
fi

impact_step "Create the administrator folder"
if impact_dir_is "$IMPACT_ADMIN_DIR" 700 root root; then
    impact_ok "The folder $IMPACT_ADMIN_DIR exists and only root can read it."
else
    impact_do "Create the folder $IMPACT_ADMIN_DIR for logs and saved states (owner root, mode 700)" \
        impact_make_dir "$IMPACT_ADMIN_DIR" 700 root root
fi

if ((${#IMPACT_CHANGES[@]} > 0)); then
    impact_undo "Remove the commands and their links: sudo $IMPACT_INSTALL_DIR/uninstall.sh"
fi
impact_summary
if ((IMPACT_DRY_RUN == 0)); then
    impact_say ''
    impact_say 'Next steps:'
    impact_say '  sudo impact-check                      look at the state of the machine'
    impact_say '  sudo impact-workstation-setup --help   prepare the workstation'
fi
