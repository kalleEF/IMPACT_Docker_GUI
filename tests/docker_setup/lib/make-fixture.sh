#!/bin/bash
# =============================================================================
# make-fixture.sh: builds the folders that the tests mount into the container
# =============================================================================
#
# PURPOSE
#   A "fixture" is a prepared set of files with known properties. This one stands for
#   the folders of a real session: the person's copy of the repository, the two result
#   folders mounted inside it, and the shared storage folder. It holds files and folders
#   that belong to three different owners, with many access modes, in nested folders,
#   with symbolic links. The start-up scripts of the image must leave every one of them
#   exactly as it is.
#
# WHEN IT RUNS
#   run-tests.sh runs it as root inside a helper container, with an empty folder of the
#   computer mounted at the path given as first argument. Root is needed to create files
#   that belong to other user numbers.
#
# ARGUMENTS
#   $1  the folder to fill
#   $2  user number of "the person" (the owner of the repository copy)
#   $3  group number of the person
#   $4  folder with the stand-in repository (tests/docker_setup/standin/repository)
#   or, to fill only a home folder (used for a Docker volume):
#   --home-only FOLDER REPOSITORY_NAME
#
# WHAT IT CREATES in $1
#   repo/       the repository copy, with the folder "mixed" (see make_mixed_tree)
#   outputs/    mounted by the tests at repo/outputs        (a mount inside a mount)
#   synthpop/   mounted by the tests at repo/inputs/synthpop (a mount inside a mount)
#   storage/    mounted by the tests outside the home folder
#   keys/       an SSH key pair made for this test run (never used anywhere else)
#   settings/   folders and a file that one test mounts over RStudio's settings folders
#   home/       a person's home folder, which one test mounts at /home/rstudio
#   homes/      a folder with two home folders (rstudio/ and otherperson/), which one
#               test mounts at /home
#
# WHAT IT NEVER TOUCHES
#   Anything outside $1.
# =============================================================================

# -e: stop at the first failing command; -u: stop when a variable was never set.
set -eu

# "${1:-}" gives the first argument, or nothing when there is none. "[[ A == B ]]"
# compares two texts.
MODE=full
if [[ "${1:-}" == "--home-only" ]]; then
    MODE=home
    ROOT="$2"
    REPO_NAME="$3"
else
    ROOT="$1"
    PERSON_UID="$2"
    PERSON_GID="$3"
    STANDIN_REPO="$4"
fi

# The three kinds of owner in the fixture:
#   1000:1000   the number the image gives to "rstudio" when it is built
#   4242:4343   a "third account": a colleague. No account of the image has these numbers.
#   0:0         root
THIRD_UID=4242
THIRD_GID=4343

# put FILE OWNER MODE TEXT: creates a file with the given owner, access mode and content.
# "NAME() { ... }" defines a function, used afterwards like a command; "$1" to "$4" are its
# arguments. "printf '%s\n' TEXT > FILE" writes TEXT and a line break into FILE.
put() {
    printf '%s\n' "$4" > "$1"
    chown "$2" "$1"
    chmod "$3" "$1"
}

# folder DIR OWNER MODE: creates a folder with the given owner and access mode.
folder() {
    mkdir -p "$1"
    chown "$2" "$1"
    chmod "$3" "$1"
}

# make_mixed_tree DIR: the heart of the fixture. Every entry differs from its neighbours
# in owner, group or access mode, so that any program that walks through the folder and
# changes owners leaves a visible trace.
make_mixed_tree() {
    # "local" makes a variable that exists only inside the function.
    local d="$1"
    folder "$d" 0:0 755

    # Owned by 1000. A change of the user number 1000 with "usermod -u" re-owns these.
    folder "$d/owned-by-1000" 1000:1000 755
    put    "$d/owned-by-1000/file-644"   1000:1000 644 "owned by 1000, readable for all"
    put    "$d/owned-by-1000/file-600"   1000:1000 600 "owned by 1000, private"
    put    "$d/owned-by-1000/script-755" 1000:1000 755 "#!/bin/sh"
    put    "$d/owned-by-1000/group-of-third" 1000:$THIRD_GID 660 "owner 1000, group of the third account"
    # The "setuid" bit (the 4 in 4755): the program runs with the rights of its owner.
    # A change of owner clears it, so a re-owned file shows in the mode as well.
    put    "$d/owned-by-1000/setuid-4755" 1000:1000 4755 "#!/bin/sh"

    # Owned by the third account.
    folder "$d/owned-by-third" $THIRD_UID:$THIRD_GID 750
    put    "$d/owned-by-third/file-640" $THIRD_UID:$THIRD_GID 640 "a colleague's file"
    put    "$d/owned-by-third/file-600" $THIRD_UID:$THIRD_GID 600 "a colleague's private file"
    put    "$d/owned-by-third/file-664" $THIRD_UID:$THIRD_GID 664 "a colleague's shared file"
    put    "$d/owned-by-third/group-1000" $THIRD_UID:1000 640 "owner third, group 1000"
    # The "setgid" bit on a file (the 2 in 2755): the program runs with the rights of its group.
    put    "$d/owned-by-third/setgid-2755" $THIRD_UID:$THIRD_GID 2755 "#!/bin/sh"

    # Owned by root.
    folder "$d/owned-by-root" 0:0 755
    put    "$d/owned-by-root/file-644" 0:0 644 "root's file"
    put    "$d/owned-by-root/file-600" 0:0 600 "root's private file"
    put    "$d/owned-by-root/file-400" 0:0 400 "root's read-only file"
    folder "$d/owned-by-root/closed-700" 0:0 700
    put    "$d/owned-by-root/closed-700/inside" 0:0 600 "inside a closed folder"

    # Nested folders, each level with another owner. The innermost has the "setgid" bit
    # (the 2 in 2775): new files in it inherit the folder's group.
    folder "$d/nested" 1000:1000 755
    folder "$d/nested/level2" $THIRD_UID:$THIRD_GID 755
    folder "$d/nested/level2/level3" 0:0 755
    folder "$d/nested/level2/level3/level4-setgid" 1000:$THIRD_GID 2775
    put    "$d/nested/level2/level3/level4-setgid/deep-1000"  1000:1000 644 "deep file of 1000"
    put    "$d/nested/level2/level3/level4-setgid/deep-third" $THIRD_UID:$THIRD_GID 600 "deep file of the third account"
    put    "$d/nested/level2/level3/level4-setgid/deep-root"  0:0 644 "deep file of root"

    # A shared folder as the workstation has them (group of the third account, setgid),
    # and a folder with the "sticky" bit (the 1 in 1777, as /tmp has it).
    folder "$d/shared-setgid" 0:$THIRD_GID 2775
    put    "$d/shared-setgid/file" $THIRD_UID:$THIRD_GID 664 "shared"
    folder "$d/sticky" 0:0 1777

    # Names with a space and with a backslash.
    folder "$d/name with spaces" 1000:1000 755
    put    "$d/name with spaces/file with spaces.txt" $THIRD_UID:$THIRD_GID 644 "spaces"
    put    "$d/back\\slash" 1000:1000 644 "backslash in the name"

    # Symbolic links: to a file and to a folder inside the tree, to a path outside it,
    # and to nothing. "chown -h" sets the owner of the link itself.
    folder "$d/links" 0:0 755
    ln -s ../owned-by-third/file-640 "$d/links/to-file-of-third"
    ln -s ../owned-by-root           "$d/links/to-folder-of-root"
    ln -s /etc/hostname              "$d/links/to-outside"
    ln -s /nonexistent/target        "$d/links/dangling"
    chown -h $THIRD_UID:$THIRD_GID "$d/links/to-file-of-third"
    chown -h 1000:1000             "$d/links/to-folder-of-root"

    # Two names for one file (a "hard link").
    put "$d/hard-a" $THIRD_UID:$THIRD_GID 644 "two names, one file"
    ln  "$d/hard-a" "$d/hard-b"

    # The one place where the tests let "rstudio" create files: mode 777 means every
    # user may write here. A new file gets the user and group number of its creator.
    folder "$d/writable" 0:0 777
}

# make_home_tree DIR REPOSITORY_NAME: a home folder as a person's real home folder on a
# computer looks: the settings folders the image also has, each with a mixed tree inside,
# and settings files of the third account. The folder for the repository mount exists,
# so that Docker creates nothing inside the mounted home folder.
make_home_tree() {
    local d="$1" entry
    folder "$d" $THIRD_UID:$THIRD_GID 750
    for entry in .config .local .cache .ssh .rstudio R; do
        make_mixed_tree "$d/$entry"
    done
    put    "$d/.bashrc"    $THIRD_UID:$THIRD_GID 600 "export FROM_OUTSIDE=1"
    put    "$d/.Rprofile"  $THIRD_UID:$THIRD_GID 600 "options(from_outside = TRUE)"
    put    "$d/.gitconfig" $THIRD_UID:$THIRD_GID 600 "[user]
	name = Name From Outside"
    folder "$d/.config/rstudio" $THIRD_UID:$THIRD_GID 755
    put    "$d/.config/rstudio/rstudio-prefs.json" $THIRD_UID:$THIRD_GID 600 '{ "note": "preferences from outside the container" }'
    put    "$d/.ssh/known_hosts" $THIRD_UID:$THIRD_GID 600 "other.example.test ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyThatBelongsToNoServerAtAll0000000000"
    folder "$d/$2" $THIRD_UID:$THIRD_GID 755
}

if [[ "$MODE" == home ]]; then
    make_home_tree "$ROOT" "$REPO_NAME"
    echo "home folder created in $ROOT"
    exit 0
fi

# --- the repository copy -----------------------------------------------------------
mkdir -p "$ROOT/repo"
cp -r "$STANDIN_REPO/." "$ROOT/repo/"
# The person owns the repository copy. "u+rwX,go+rX" gives the owner all rights and the
# others the right to read; the capital X adds the right to enter folders.
chown -R "$PERSON_UID:$PERSON_GID" "$ROOT/repo"
chmod -R u+rwX,go+rX "$ROOT/repo"
make_mixed_tree "$ROOT/repo/mixed"
put "$ROOT/repo/top-file-of-root"  0:0 600 "root's file at the top of the repository"
put "$ROOT/repo/top-file-of-third" $THIRD_UID:$THIRD_GID 640 "a colleague's file at the top of the repository"
put "$ROOT/repo/top-file-of-1000"  1000:1000 644 "a file of 1000 at the top of the repository"

# --- the two result folders (mounted inside the repository) and the storage ---------
make_mixed_tree "$ROOT/outputs"
make_mixed_tree "$ROOT/synthpop"
make_mixed_tree "$ROOT/storage"
# In the storage, the model writes below "outputs". The tests create files there.
folder "$ROOT/storage/outputs" 0:0 777

# --- an SSH key pair for this run -----------------------------------------------------
# ssh-keygen: -q quiet, -t the key type, -N '' no passphrase, -C a comment, -f the file.
mkdir -p "$ROOT/keys"
ssh-keygen -q -t ed25519 -N '' -C "impact docker_setup test key" -f "$ROOT/keys/id_ed25519_testuser"
# As on the workstation: the key copy belongs to the person and is private.
chown "$PERSON_UID:$PERSON_GID" "$ROOT/keys/id_ed25519_testuser" "$ROOT/keys/id_ed25519_testuser.pub"
chmod 600 "$ROOT/keys/id_ed25519_testuser"
chmod 644 "$ROOT/keys/id_ed25519_testuser.pub"

# --- content for the test "a settings folder is itself a mount" ---------------------
folder "$ROOT/settings" 0:0 755
folder "$ROOT/settings/config-rstudio" $THIRD_UID:$THIRD_GID 755
put    "$ROOT/settings/config-rstudio/rstudio-prefs.json" $THIRD_UID:$THIRD_GID 644 '{ "note": "preferences from outside the container" }'
folder "$ROOT/settings/ssh" $THIRD_UID:$THIRD_GID 700
put    "$ROOT/settings/ssh/known_hosts" $THIRD_UID:$THIRD_GID 644 "other.example.test ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyThatBelongsToNoServerAtAll0000000000"
put    "$ROOT/settings/ssh/config" $THIRD_UID:$THIRD_GID 600 "# ssh settings from outside the container"
folder "$ROOT/settings/local" $THIRD_UID:$THIRD_GID 755
put    "$ROOT/settings/local/marker" $THIRD_UID:$THIRD_GID 644 "state from outside the container"
put    "$ROOT/settings/gitconfig" $THIRD_UID:$THIRD_GID 644 "[user]
	name = Name From Outside"

# --- a mounted home folder, and a mounted /home -----------------------------------------
# The repository folder name is the last part of the repository path in the tests.
make_home_tree "$ROOT/home" IMPACT_Standin_Model
folder "$ROOT/homes" 0:0 755
make_home_tree "$ROOT/homes/rstudio" IMPACT_Standin_Model
make_mixed_tree "$ROOT/homes/otherperson"

echo "fixture created in $ROOT for the person $PERSON_UID:$PERSON_GID"
