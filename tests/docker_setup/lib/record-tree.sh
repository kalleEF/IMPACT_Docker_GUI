#!/bin/bash
# =============================================================================
# record-tree.sh: writes down the state of every entry in one or more folders
# =============================================================================
#
# PURPOSE
#   Prints one line per file, folder and symbolic link. run-tests.sh calls it before a
#   container starts and again afterwards and compares the two lists. Any difference
#   means that something touched a mounted folder.
#
# WHEN IT RUNS
#   As root inside a helper container, with the folders mounted read-only.
#   Root is needed to look into folders that are closed for other users.
#
# ARGUMENTS
#   Pairs of LABEL and FOLDER. The label is printed in front of every line of that folder.
#
# WHAT IT CHANGES
#   Nothing. It only reads.
#
# WHAT IT NEVER TOUCHES
#   Every file: no owner, no access mode, no content and no time changes. run-tests.sh
#   mounts the folders read-only for this script, so not even a time of last access can
#   change.
#
# THE LINE
#   label|path|type|owner:group|mode|size|modified|changed|link target
#     type       f file, d folder, l symbolic link
#     mode       the access rights as a number, for example 644
#     modified   time of the last change of the content
#     changed    time of the last change of content, owner, group or mode. Linux sets
#                this time itself and offers no way to set it back, so a "chown" that
#                is undone afterwards still shows here.
#   Both times are printed in seconds with nine decimals.
# =============================================================================
# "set -eu": -e stops the script at the first failing command, -u stops it when it reads
# a variable that was never set.
set -eu

# "$#" is the number of arguments; "[ A -ge B ]" is true when the whole number A is
# greater than or equal to B. "$1" and "$2" are the first two arguments; "shift 2" drops
# them, so the next pair moves to the front.
while [ "$#" -ge 2 ]; do
    label="$1"
    dir="$2"
    shift 2
    # find -printf writes one line per entry: %P path below the folder, %y type,
    # %U:%G owner and group as numbers, %m mode, %s size, %T@ modified, %C@ changed,
    # %l target of a link. "|" passes the lines to the next command. awk, a small
    # text-processing language, splits each line at "|" (-F'|'), puts "-" in place of the
    # size ($6) of a folder (type "d" in $3) and prints the line. The size of a folder is
    # left out because it depends on the file system. "LC_ALL=C sort" sorts byte by byte,
    # the same on every computer. find never follows a symbolic link when it walks.
    find "$dir" -printf "$label|%P|%y|%U:%G|%m|%s|%T@|%C@|%l\n" \
        | awk -F'|' -v OFS='|' '$3 == "d" {$6 = "-"} {print}' \
        | LC_ALL=C sort
done
