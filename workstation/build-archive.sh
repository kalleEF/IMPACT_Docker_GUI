#!/bin/bash
# =============================================================================
# build-archive.sh: build the delivery archive of the workstation commands
#
# Purpose
#   Packs the workstation commands into one file that can be copied to the
#   workstation: impact-workstation-<version>.tar.gz. It holds the commands
#   (bin/), their shared files (lib/), the example settings file and
#   GitHub's host keys (etc/), install.sh, uninstall.sh, VERSION and
#   README.md, inside one folder impact-workstation-<version>/.
#   It prints the SHA-256 checksum of the archive: a long code that changes
#   when even one byte of the file changes. Compare it on the workstation
#   before you install, so you know the copy arrived complete and unchanged.
#   Two builds from the same files give the same archive and the same
#   checksum (fixed owner, order and times inside the archive).
#
# Who runs it
#   A developer, on any Linux computer with bash, tar, gzip and sha256sum,
#   from a copy of the repository. No sudo is needed. It is not installed
#   on the workstation.
#
# Usage
#   bash workstation/build-archive.sh [--output-dir <folder>]
#
# Examples
#   bash workstation/build-archive.sh
#       writes ./impact-workstation-2.1.0.tar.gz (and .sha256) in the
#       current folder
#   bash workstation/build-archive.sh --output-dir /tmp/delivery
#   bash workstation/build-archive.sh --help
#   On the workstation, after copying both files there:
#       sha256sum -c impact-workstation-2.1.0.tar.gz.sha256
#       tar -xzf impact-workstation-2.1.0.tar.gz
#       cd impact-workstation-2.1.0 && sudo ./install.sh --dry-run
#
# Options
#   --output-dir <folder>   where the archive goes (default: the current
#                           folder); the folder must exist
#   --help                  show this text
#
# What it changes on the system
#   It writes two files into the output folder:
#   impact-workstation-<version>.tar.gz and
#   impact-workstation-<version>.tar.gz.sha256 (the checksum line in the
#   form that "sha256sum -c" reads). An older file of the same name is
#   replaced. A temporary folder in /tmp is removed at the end. Nothing
#   else changes.
#
# How to undo
#   Delete the two files.
#
# Exit codes
#   0 the archive was written; 1 a check of the files failed or a step
#   failed; 2 wrong usage.
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
#   trap 'command' EXIT  run the command when the script ends, for any reason
#   while IFS= read -r line   read input line by line, exactly as written:
#                        "IFS=" keeps blanks at both ends, -r keeps backslashes
#   $'\t'  $'\r'  $'\n'   a text with a special character: tab, carriage return,
#                        new line (\xNN is the byte NN)
#   command || true      accept a failure of this command ("set -e" would
#                        otherwise stop the script there)
#   2>&1                 send the error channel to the same place as the output
#   shopt -s nullglob    a file pattern (*.conf) without a match gives an empty
#                        list; "shopt -u" switches this off again
# Constructs beyond these are explained where they are first used.
# -----------------------------------------------------------------------------

# "set -e" stops the script at the first command that fails, "-u" stops it
# when a variable is read that was never set, and "-o pipefail" makes a chain
# of commands joined with "|" fail when any part of it fails.
set -euo pipefail

# Tool output in its fixed English form, and a fixed sort order.
export LC_ALL=C

# The folder of this script is the folder "workstation" of the repository.
# "${BASH_SOURCE[0]}" is the path of this file; "pwd -P" prints the folder
# with every symbolic link resolved.
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# die TEXT
#   Prints an error and ends the script with exit code 1.
die() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

# die_usage TEXT
#   Prints an error about the usage and ends the script with exit code 2.
die_usage() {
    printf 'ERROR: %s\nRun "bash %s --help" to see the usage.\n' "$1" "$0" >&2
    exit 2
}

# show_help
#   Prints the comment block at the top of this file, without the "# ".
show_help() {
    sed -n '2,/^# =\{10,\}$/p' -- "${BASH_SOURCE[0]}" | sed -e '1d' -e '$d' -e 's/^# \{0,1\}//'
}

# -----------------------------------------------------------------------------
# 1. Options
# -----------------------------------------------------------------------------
OUTPUT_DIR="$PWD"
while (($# > 0)); do
    case "$1" in
        --help)
            show_help
            exit 0
            ;;
        --output-dir)
            (($# >= 2)) || die_usage "--output-dir needs a folder."
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --output-dir=*)
            OUTPUT_DIR="${1#--output-dir=}"
            shift
            ;;
        *)
            die_usage "Unknown argument '$1'."
            ;;
    esac
done
[[ -d "$OUTPUT_DIR" ]] || die_usage "The output folder '$OUTPUT_DIR' does not exist."
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd -P)"

for tool in tar gzip sha256sum find sort stat mktemp; do
    # "command -v" finds a program; only its status counts here.
    command -v "$tool" >/dev/null 2>&1 || die "The tool $tool is missing."
done

# -----------------------------------------------------------------------------
# 2. The files of the archive, and checks of them
# -----------------------------------------------------------------------------
IFS= read -r VERSION <"$SOURCE_DIR/VERSION" || true
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "$SOURCE_DIR/VERSION does not hold a version such as 2.1.0."
fi
NAME="impact-workstation-$VERSION"
ARCHIVE="$OUTPUT_DIR/$NAME.tar.gz"

# The files, as paths inside the folder workstation. The two lists differ in
# the mode the files get in the archive: 755 (programs) or 644.
PROGRAMS=(install.sh uninstall.sh)
OTHERS=(README.md VERSION etc/impact.conf.example etc/github_known_hosts)
# "nullglob": a pattern without any match expands to nothing.
shopt -s nullglob
for file in "$SOURCE_DIR"/bin/impact-*; do
    PROGRAMS+=("bin/$(basename -- "$file")")
done
for file in "$SOURCE_DIR"/lib/impact-*.sh; do
    OTHERS+=("lib/$(basename -- "$file")")
done
shopt -u nullglob

COMMAND_COUNT=0
for file in "${PROGRAMS[@]}" "${OTHERS[@]}"; do
    full="$SOURCE_DIR/$file"
    if [[ ! -f "$full" || -L "$full" ]]; then
        die "$full is missing or is no plain file."
    fi
    case "$file" in
        bin/* | lib/* | install.sh | uninstall.sh)
            # Every script starts with the bash line and passes bash's own
            # syntax check ("bash -n" reads the file and runs nothing).
            IFS= read -r first_line <"$full" || true
            [[ "$first_line" == '#!/bin/bash' ]] || die "$full does not start with the line #!/bin/bash."
            bash -n -- "$full" || die "$full has a syntax error."
            # A Windows line end in a script breaks bash on the workstation.
            if grep -q $'\r' -- "$full"; then
                die "$full contains Windows line ends."
            fi
            ;;
        *) ;;
    esac
    if [[ "$file" == bin/* ]]; then
        COMMAND_COUNT=$((COMMAND_COUNT + 1))
    fi
done
((COMMAND_COUNT > 0)) || die "No command was found in $SOURCE_DIR/bin."
for file in impact-common.sh impact-settings.sh impact-accounts.sh impact-storage.sh impact-ssh.sh impact-docker.sh; do
    [[ -f "$SOURCE_DIR/lib/$file" ]] || die "The library file lib/$file is missing."
done

# -----------------------------------------------------------------------------
# 3. The archive
# -----------------------------------------------------------------------------
STAGING="$(mktemp -d /tmp/impact-archive.XXXXXXXXXX)"
# The archive is written under a temporary name first and renamed when it is
# complete, so a half-written file never carries the real name.
TEMPORARY="$OUTPUT_DIR/.$NAME.tar.gz.partial"
# The temporary folder and an unfinished archive go, however the script ends.
trap 'rm -rf -- "$STAGING" "$TEMPORARY"' EXIT

mkdir -p -- "$STAGING/$NAME/bin" "$STAGING/$NAME/lib" "$STAGING/$NAME/etc"
for file in "${PROGRAMS[@]}"; do
    install -m 755 -- "$SOURCE_DIR/$file" "$STAGING/$NAME/$file"
done
for file in "${OTHERS[@]}"; do
    install -m 644 -- "$SOURCE_DIR/$file" "$STAGING/$NAME/$file"
done
chmod 755 -- "$STAGING/$NAME" "$STAGING/$NAME/bin" "$STAGING/$NAME/lib" "$STAGING/$NAME/etc"

# One fixed time for every entry: the newest change time among the files,
# or SOURCE_DATE_EPOCH when the caller sets it (a common convention for
# builds that must give the same result twice).
if [[ "${SOURCE_DATE_EPOCH:-}" =~ ^[0-9]+$ ]]; then
    STAMP="$SOURCE_DATE_EPOCH"
else
    STAMP=0
    for file in "${PROGRAMS[@]}" "${OTHERS[@]}"; do
        time_of_file="$(stat -c '%Y' -- "$SOURCE_DIR/$file")"
        if ((time_of_file > STAMP)); then
            STAMP="$time_of_file"
        fi
    done
fi

# tar options: --sort=name a fixed order; --owner/--group/--numeric-owner
# every entry belongs to root (number 0) whoever builds; --mtime the fixed
# time. "gzip -n" leaves the name and time of the file out of the
# compressed data, so the result depends on the content only.
tar --create --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$STAMP" \
    --format=gnu --directory="$STAGING" -- "$NAME" | gzip -n -9 >"$TEMPORARY"
# "mv -f -T" puts the finished file in place in one step.
mv -f -T -- "$TEMPORARY" "$ARCHIVE"

# The checksum, and a file with it in the form "sha256sum -c" reads.
CHECKSUM="$(sha256sum -- "$ARCHIVE" | cut -d' ' -f1)"
printf '%s  %s\n' "$CHECKSUM" "$NAME.tar.gz" >"$ARCHIVE.sha256"

printf 'Archive:   %s\n' "$ARCHIVE"
printf 'Content:   %d commands, %d files in all, in the folder %s/\n' \
    "$COMMAND_COUNT" "$((${#PROGRAMS[@]} + ${#OTHERS[@]}))" "$NAME"
printf 'Size:      %s bytes\n' "$(stat -c '%s' -- "$ARCHIVE")"
printf 'SHA-256:   %s\n' "$CHECKSUM"
printf 'Checksum file: %s\n' "$ARCHIVE.sha256"
printf '\nOn the workstation, with both files in one folder:\n'
printf '  sha256sum -c %s.tar.gz.sha256      must print: %s.tar.gz: OK\n' "$NAME" "$NAME"
printf '  tar -xzf %s.tar.gz && cd %s && sudo ./install.sh --dry-run\n' "$NAME" "$NAME"
