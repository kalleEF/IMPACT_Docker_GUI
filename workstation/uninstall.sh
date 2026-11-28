#!/bin/bash
# =============================================================================
# uninstall.sh: remove the IMPACT workstation commands
#
# Purpose
#   Removes the commands and their links, and nothing else. Everything the
#   commands created while they were in use stays on the machine; this script
#   lists what stays and how to remove each part by hand.
#
# Who runs it
#   The administrator of the workstation, with sudo.
#
# Usage
#   sudo /opt/impact/uninstall.sh [--dry-run]
#
# Examples
#   sudo /opt/impact/uninstall.sh --dry-run    show every step, change nothing
#   sudo /opt/impact/uninstall.sh              remove the commands
#   /opt/impact/uninstall.sh --help            show this text
#
# What it changes on the system
#   Removes: /usr/local/bin/impact-* (only links that point to
#   /opt/impact/bin), /opt/impact/bin, /opt/impact/lib, /opt/impact/etc,
#   /opt/impact/VERSION and /opt/impact/uninstall.sh.
#   Keeps: the accounts, the shared group, /etc/impact (settings), the SSH
#   rules, the model folders, the shared storage, and /opt/impact/admin with
#   the log and the saved states.
#   Order: to remove the SSH rules as well, run
#   "sudo impact-workstation-setup --remove-ssh-rules" BEFORE this script,
#   because that command does it with all safety checks and is removed by
#   this script. The script names this before it removes anything. Without
#   that step the rules stay and keep the members restricted to key login.
#   A second run, after /opt/impact/uninstall.sh is gone, starts from the
#   unpacked folder: sudo ./uninstall.sh
#
# How to undo
#   Unpack the archive again and run: sudo ./install.sh
#
# Exit codes
#   0 done or nothing to do; 1 a step failed; 2 wrong usage.
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
#   shopt -s nullglob    a file pattern (*.conf) without a match gives an empty
#                        list; "shopt -u" switches this off again
# Constructs beyond these are explained where they are first used.
# -----------------------------------------------------------------------------

# "set -e" stops the script at the first command that fails, "-u" stops it
# when a variable is read that was never set, and "-o pipefail" makes a chain
# of commands joined with "|" fail when any part of it fails.
set -euo pipefail

# The folder this script lies in: /opt/impact after an installation, or the
# unpacked folder. In both places the shared functions lie in "lib" next to
# it. bash keeps them in memory, so this script can remove its own files.
# "${BASH_SOURCE[0]}" is the path of this file; "readlink -f" resolves every
# symbolic link in it.
IMPACT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname -- "$IMPACT_SELF")"
if [[ ! -r "$SELF_DIR/lib/impact-common.sh" ]]; then
    printf 'ERROR: %s/lib/impact-common.sh is missing, so uninstall.sh cannot run from here.\n' "$SELF_DIR" >&2
    printf 'What to do: unpack the archive and run the uninstall.sh of the unpacked folder.\n' >&2
    exit 1
fi
# The two comment lines below tell the checking tool "shellcheck" where the
# loaded file is.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/impact-common.sh
source "$SELF_DIR/lib/impact-common.sh"
impact_init "$IMPACT_SELF"

impact_parse_args 'dry-run' '' '' "$@"
impact_require_arg_count 0 0
impact_require_root
impact_log_enable "$@"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

# remove_paths PATH...
#   Removes the given files or folders with their content.
remove_paths() {
    rm -rf -- "$@"
}

# -----------------------------------------------------------------------------
# The steps
# -----------------------------------------------------------------------------

impact_step "Find the installed commands"
LINKS=()       # links in /usr/local/bin that belong to the installation
FOREIGN=()     # entries named impact-* that do not belong to it
# "nullglob" makes a pattern without any match expand to nothing.
shopt -s nullglob
for link in "$IMPACT_LINK_DIR"/impact-*; do
    if [[ -L "$link" && "$(readlink -- "$link")" == "$IMPACT_BIN_DIR"/* ]]; then
        LINKS+=("$link")
    else
        FOREIGN+=("$link")
    fi
done
shopt -u nullglob
PARTS=()       # the parts of /opt/impact that hold the commands
for part in bin lib etc VERSION uninstall.sh .new-bin .new-lib .new-etc .old-bin .old-lib .old-etc; do
    if [[ -e "$IMPACT_INSTALL_DIR/$part" || -L "$IMPACT_INSTALL_DIR/$part" ]]; then
        PARTS+=("$IMPACT_INSTALL_DIR/$part")
    fi
done
impact_info "Links in $IMPACT_LINK_DIR: ${#LINKS[@]}. Parts in $IMPACT_INSTALL_DIR: ${#PARTS[@]}."
if ((${#FOREIGN[@]} > 0)); then
    impact_warn "These entries are named like IMPACT commands and do not belong to the installation. They stay: ${FOREIGN[*]}"
fi
# The SSH rules are removed safely by a command that this script removes, so
# the order is named before anything is removed.
if [[ -e "$IMPACT_SSH_RULES_FILE" && -x "$IMPACT_BIN_DIR/impact-workstation-setup" ]]; then
    impact_info "The SSH rules $IMPACT_SSH_RULES_FILE stay (members stay restricted to key login). To remove them as well, first run: sudo impact-workstation-setup --remove-ssh-rules  (it needs the commands, so before this script)."
fi

# Read the settings, when there are any, to name the group and the model
# folder in the list of things that stay. A missing or invalid file is fine.
GROUP_TEXT='the shared group (default name: impact)'
MODEL_TEXT='/srv/impact/models (the default place)'
if impact_conf_load 2>/dev/null; then
    GROUP_TEXT="the group ${IMPACT_CONF[SHARED_GROUP]}"
    MODEL_TEXT="${IMPACT_CONF[MODEL_DIR]}"
fi

impact_step "Remove the links and the commands"
if ((${#LINKS[@]} > 0)); then
    impact_do "Remove the links from $IMPACT_LINK_DIR (number of links: ${#LINKS[@]})" remove_paths "${LINKS[@]}"
else
    impact_ok "There are no links to remove."
fi
if ((${#PARTS[@]} > 0)); then
    impact_do "Remove the commands and their shared files: ${PARTS[*]}" remove_paths "${PARTS[@]}"
else
    impact_ok "There are no commands to remove."
fi
if ((${#IMPACT_CHANGES[@]} > 0)); then
    impact_undo "Install the commands again from the unpacked archive: sudo ./install.sh"
fi

impact_step "What stays on this machine, and how to remove each part by hand"
impact_info "Personal accounts and their home folders (with the working copies)."
impact_info "    One account:  sudo userdel <account>    with its home folder:  sudo userdel --remove <account>"
impact_info "Group: $GROUP_TEXT."
impact_info "    After its members were removed:  sudo groupdel <group>"
if [[ -e "$IMPACT_CONF_DIR" ]]; then
    impact_info "Settings: $IMPACT_CONF_DIR (exists)."
else
    impact_info "Settings: $IMPACT_CONF_DIR (not present)."
fi
impact_info "    sudo rm -r $IMPACT_CONF_DIR"
if [[ -e "$IMPACT_SSH_RULES_FILE" ]]; then
    impact_info "SSH rules: $IMPACT_SSH_RULES_FILE (exists; members of the group stay restricted to key login)."
    if [[ -x "$IMPACT_BIN_DIR/impact-workstation-setup" ]] || impact_is_dry_run; then
        impact_info "    The safe way, while the commands are still installed (before this script):  sudo impact-workstation-setup --remove-ssh-rules"
    else
        impact_info "    The safe way needs the commands, which are removed now: install them again from the unpacked folder (sudo ./install.sh), run  sudo impact-workstation-setup --remove-ssh-rules,  then remove the commands again from the unpacked folder (sudo ./uninstall.sh)."
    fi
    impact_info "    By hand: keep one session open, then:  sudo rm $IMPACT_SSH_RULES_FILE && sudo sshd -t && sudo systemctl reload ssh"
    impact_info "    (On Ubuntu 24.04 the reload can answer that ssh.service is not active; new logins then read the change by themselves.)"
    impact_info "    Test a new login from a second window before you close the first one."
else
    impact_info "SSH rules: $IMPACT_SSH_RULES_FILE (not present)."
fi
impact_info "Model folders: $MODEL_TEXT. The extras there can be the only copy of files that are not on GitHub."
impact_info "    sudo rm -r <model folder>"
impact_info "Shared storage: the folders on the storage disks and their access rules stay as they are."
if [[ -e "$IMPACT_ADMIN_DIR" ]]; then
    impact_info "Administrator folder: $IMPACT_ADMIN_DIR (exists) with the log, saved keys and saved states."
else
    impact_info "Administrator folder: $IMPACT_ADMIN_DIR (not present)."
fi
impact_info "    Copy what you still need, then:  sudo rm -r $IMPACT_ADMIN_DIR"
impact_info "Docker, its images and containers are not touched."

impact_summary
