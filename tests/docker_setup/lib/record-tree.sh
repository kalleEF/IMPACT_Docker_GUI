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
set -eu

# "$#" is the number of arguments; "shift 2" drops the first two.
while [ "$#" -ge 2 ]; do
    label="$1"
    dir="$2"
    shift 2
    # find -printf writes one line per entry: %P path below the folder, %y type,
    # %U:%G owner and group as numbers, %m mode, %s size, %T@ modified, %C@ changed,
    # %l target of a link. "LC_ALL=C sort" sorts byte by byte, the same on every computer.
    # The size of a folder is left out (it depends on the file system).
    find "$dir" -printf "$label|%P|%y|%U:%G|%m|%s|%T@|%C@|%l\n" \
        | awk -F'|' -v OFS='|' '$3 == "d" {$6 = "-"} {print}' \
        | LC_ALL=C sort
done
