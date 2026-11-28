#!/bin/bash
# =============================================================================
# storage-10-sharing-library.test.sh: unit tests for the pure parts of
# impact-sharing.sh
#
# Purpose
#   Proves, without root and without changing the system:
#     - names as getfacl and /proc/self/mountinfo print them are turned back
#       into the real names (blanks, line breaks, backslashes);
#     - a path is quoted correctly for a "find -path" pattern;
#     - backup folder names are built and checked as intended;
#     - the deviation test of the walk (an awk program) gives the right
#       reasons for folders and files of every relevant kind, also with a
#       transition account, and writes the records of deviating entries in
#       the getfacl format with the two extra lines;
#     - the records of a backup are read back into one line per entry;
#     - the chmod instruction for the special bits, number and size texts;
#     - the image names and numbers that may reach "docker image rm", and
#       the keep-or-remove rule of impact-clean-images;
#     - the content code of impact-export-state depends on content, mode
#       and names in the archive, and not on times.
#   The walk itself, the restore and the three commands are tested as root
#   in ../system (storage-*.test.sh).
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (no special rights needed)
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter storage-10
#
# What it changes on the system
#   Nothing outside the temporary folder of the test.
#
# How to undo
#   Nothing to undo.
# =============================================================================

# Reading help: the bash constructs used here are explained at the top of
# ../lib/testlib.sh ("Reading help") and where they are first used.

# The lines for the checking tool "shellcheck" stand before the first command
# of the file and therefore count for the whole file.
# shellcheck disable=SC2016
# Reason for SC2016 (no expansion in single quotes): many texts in this file
# are test data that must stay exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

setup() {
    load_library
    # shellcheck source=../../../workstation/lib/impact-sharing.sh
    source "$WORKSTATION_DIR/lib/impact-sharing.sh"
}

# ----------------------------------------------------------------------------
# Names
# ----------------------------------------------------------------------------

# Unescape turns escaped names back.
test_unescape_turns_escaped_names_back() {
    impact_sharing_unescape '/mnt/disk_a/plain-name.csv'
    assert_eq '/mnt/disk_a/plain-name.csv' "$IMPACT_SHARING_TEXT"
    impact_sharing_unescape 'a\040b'
    assert_eq 'a b' "$IMPACT_SHARING_TEXT"
    impact_sharing_unescape 'line\012break'
    assert_eq $'line\nbreak' "$IMPACT_SHARING_TEXT"
    impact_sharing_unescape 'back\\slash'
    assert_eq 'back\slash' "$IMPACT_SHARING_TEXT"
    # An escaped backslash followed by digits stays a backslash and digits.
    impact_sharing_unescape 'x\\012y'
    assert_eq 'x\012y' "$IMPACT_SHARING_TEXT"
    # A line break at the very end survives (no "$( )" in between).
    impact_sharing_unescape 'end\012'
    assert_eq $'end\n' "$IMPACT_SHARING_TEXT"
    # Text that only looks like a command stays text.
    impact_sharing_unescape '$(touch x)\073'
    assert_eq '$(touch x);' "$IMPACT_SHARING_TEXT"
}

# Glob quote protects pattern characters.
test_glob_quote_protects_pattern_characters() {
    assert_eq '/mnt/a\*b\?c\[d]' "$(impact_sharing_glob_quote '/mnt/a*b?c[d]')"
    assert_eq '/mnt/back\\slash' "$(impact_sharing_glob_quote '/mnt/back\slash')"
    assert_eq '/mnt/with space' "$(impact_sharing_glob_quote '/mnt/with space')"
}

# Backup folder names are made from the time and the path, and nothing else
# passes as one.
test_backup_names() {
    assert_eq '20261124T201500Z_mnt_disk_a_shared_Example' \
        "$(impact_sharing_backup_name /mnt/disk_a/shared/Example 20261124T201500Z)"
    assert_success impact_sharing_valid_backup_name 20261124T201500Z_mnt_disk_a_shared_Example
    assert_success impact_sharing_valid_backup_name 20261124T201500Z_mnt_disk_a_shared_Example-2
    assert_fails impact_sharing_valid_backup_name ../../etc
    assert_fails impact_sharing_valid_backup_name 20261124T201500Z_a/b
    assert_fails impact_sharing_valid_backup_name '20261124T201500Z_a b'
    assert_fails impact_sharing_valid_backup_name 20261124T201500Z_
    assert_fails impact_sharing_valid_backup_name log
    # A very long path gives a name that still fits a folder name.
    local long
    long="/mnt/$(printf 'x%.0s' {1..240})"
    long="$(impact_sharing_backup_name "$long" 20261124T201500Z)"
    assert_success impact_sharing_valid_backup_name "$long"
}

# ----------------------------------------------------------------------------
# The deviation test of the walk
# ----------------------------------------------------------------------------

# A getfacl record (as "getfacl -P -p -n -E" prints it) for one entry.
# record PATH GROUP FLAGS ENTRY...
record() {
    local path="$1" group="$2" flags="$3"
    shift 3
    printf '# file: %s\n# owner: 2001\n# group: %s\n' "$path" "$group"
    if [[ "$flags" != '---' ]]; then
        printf '# flags: %s\n' "$flags"
    fi
    printf '%s\n' "$@"
    printf '\n'
}

# classify_one KIND STATE RECORD_TEXT
#   Prints the reasons the deviation test gives for one entry. The shared
#   group has the number 1005; the transition account the number 1001.
classify_one() {
    local info="$TEST_TMP/info" uid=''
    printf '%s 64768 4242\n' "$1" >"$info"
    if [[ -n "$2" ]]; then
        uid=1001
    fi
    printf '%s' "$3" | impact_sharing_classify "$info" 1005 "$uid" "$2" '' | sed -n 's/^0 //p'
}

# Folder that follows the rules.
test_folder_that_follows_the_rules() {
    local good
    good="$(record /s/d 1005 -s- user::rwx group::rwx other::r-x default:user::rwx default:group::rwx default:other::r-x)"
    assert_eq '-' "$(classify_one d '' "$good")"
}

# Each way a folder can deviate from the shared rules gets its own reason word
# (group, setgid, access, default).
test_folder_reasons() {
    assert_eq 'group,setgid,access,default' \
        "$(classify_one d '' "$(record /s/d 2001 --- user::rwx group::r-x other::r-x)")"
    # The mask limits the group.
    assert_eq 'access' "$(classify_one d '' "$(record /s/d 1005 -s- user::rwx user:2002:rwx group::rwx mask::r-x other::r-x \
        default:user::rwx default:group::rwx default:other::r-x)")"
    # The default ACL gives others other rights than the folder itself.
    assert_eq 'default' "$(classify_one d '' "$(record /s/d 1005 -s- user::rwx group::rwx other::r-x \
        default:user::rwx default:group::rwx default:other::---)")"
    # A default mask limits new entries.
    assert_eq 'default' "$(classify_one d '' "$(record /s/d 1005 -s- user::rwx group::rwx other::--- \
        default:user::rwx default:group::rwx default:mask::r-x default:other::---)")"
    # setuid and sticky are not setgid.
    assert_eq 'setgid' "$(classify_one d '' "$(record /s/d 1005 s-t user::rwx group::rwx other::--- \
        default:user::rwx default:group::rwx default:other::---)")"
}

# Folder with transition account.
test_folder_with_transition_account() {
    local base=(user::rwx group::rwx other::--- default:user::rwx default:group::rwx default:other::---)
    assert_eq 'user' "$(classify_one d present "$(record /s/d 1005 -s- "${base[@]}")")"
    assert_eq 'user' "$(classify_one d present "$(record /s/d 1005 -s- user::rwx user:1001:rwx group::rwx mask::rwx other::--- \
        default:user::rwx default:group::rwx default:other::---)")"
    assert_eq '-' "$(classify_one d present "$(record /s/d 1005 -s- user::rwx user:1001:rwx group::rwx mask::rwx other::--- \
        default:user::rwx default:user:1001:rwx default:group::rwx default:mask::rwx default:other::---)")"
    assert_eq '-' "$(classify_one d absent "$(record /s/d 1005 -s- "${base[@]}")")"
    assert_eq 'user' "$(classify_one d absent "$(record /s/d 1005 -s- "${base[@]}" default:user:1001:rwx)")"
    # Another account's entry is no reason.
    assert_eq '-' "$(classify_one d absent "$(record /s/d 1005 -s- user::rwx user:1002:rwx group::rwx mask::rwx other::--- \
        default:user::rwx default:group::rwx default:other::---)")"
}

# Each way a file can deviate from the shared rules gets its own reason word,
# and a group with more rights than the owner is fine.
test_file_reasons() {
    assert_eq '-' "$(classify_one f '' "$(record /s/f 1005 --- user::rw- group::rw- other::r--)")"
    assert_eq '-' "$(classify_one f '' "$(record /s/f 1005 --- user::rwx group::rwx other::r-x)")"
    # The group may execute without the owner: no reason.
    assert_eq '-' "$(classify_one f '' "$(record /s/f 1005 --- user::rw- group::rwx other::---)")"
    assert_eq 'group' "$(classify_one f '' "$(record /s/f 2001 --- user::rw- group::rw- other::r--)")"
    assert_eq 'group,access' "$(classify_one f '' "$(record /s/f 2001 --- user::rw- group::r-- other::r--)")"
    # The owner may execute, the group not.
    assert_eq 'access' "$(classify_one f '' "$(record /s/f 1005 --- user::rwx group::rw- other::r--)")"
    # The mask removes group write ("chmod g-w" on a file with an ACL).
    assert_eq 'access' "$(classify_one f '' "$(record /s/f 1005 --- user::rw- user:2002:rw- group::rw- mask::r-- other::r--)")"
    # The owning group entry lacks write while the mask allows it.
    assert_eq 'access' "$(classify_one f '' "$(record /s/f 1005 --- user::rw- user:2002:rw- group::r-- mask::rw- other::r--)")"
    # An executable file whose mask removes execute.
    assert_eq 'access' "$(classify_one f '' "$(record /s/f 1005 --- user::rwx user:2002:rwx group::rwx mask::rw- other::r--)")"
}

# File with transition account.
test_file_with_transition_account() {
    assert_eq 'user' "$(classify_one f present "$(record /s/f 1005 --- user::rw- group::rw- other::r--)")"
    assert_eq 'user' "$(classify_one f present "$(record /s/f 1005 --- user::rw- user:1001:r-- group::rw- mask::rw- other::r--)")"
    assert_eq '-' "$(classify_one f present "$(record /s/f 1005 --- user::rw- user:1001:rwx group::rwx mask::rw- other::r--)")"
    assert_eq 'user' "$(classify_one f absent "$(record /s/f 1005 --- user::rw- user:1001:rw- group::rw- mask::rw- other::r--)")"
    assert_eq '-' "$(classify_one f absent "$(record /s/f 1005 --- user::rw- group::rw- other::r--)")"
}

# Classify counts and saves only deviating records.
test_classify_counts_and_saves_only_deviating_records() {
    local info="$TEST_TMP/info" backup="$TEST_TMP/backup" output
    printf 'd 64768 11\nf 64768 12\nf 64768 13\n' >"$info"
    {
        record '/s/a b' 1005 -s- user::rwx group::rwx other::--- default:user::rwx default:group::rwx default:other::---
        record '/s/a b/new\012line' 2001 --- user::rw- group::r-- other::---
        record '/s/a b/ok' 1005 --- user::rw- group::rw- other::---
    } >"$TEST_TMP/records"
    output="$(impact_sharing_classify "$info" 1005 '' '' "$backup" <"$TEST_TMP/records")"
    assert_eq $'0 -\n1 group,access\n2 -\nCOUNT 3' "$output"
    assert_eq $'# file: /s/a b/new\\012line\n# impact-type: f\n# impact-inode: 64768:12\n# owner: 2001\n# group: 2001\nuser::rw-\ngroup::r--\nother::---' \
        "$(cat -- "$backup")"
    # A missing line in the info file is reported, so the caller can fall
    # back to one entry at a time.
    printf 'd 64768 11\n' >"$info"
    output="$(impact_sharing_classify "$info" 1005 '' '' '' <"$TEST_TMP/records")"
    assert_contains "$output" 'BROKEN'
}

# Effective remarks do not confuse the test.
test_effective_remarks_do_not_confuse_the_test() {
    # Without -E getfacl adds "#effective:" remarks; they must not count.
    local text
    text="$(printf '# file: /s/f\n# owner: 1\n# group: 1005\nuser::rw-\nuser:2002:rw-\t#effective:r--\ngroup::rw-\t#effective:r--\nmask::r--\nother::r--\n\n')"
    assert_eq 'access' "$(classify_one f '' "$text")"
}

# Normalize gives one line per entry.
test_normalize_gives_one_line_per_entry() {
    local output
    output="$({
        printf '# file: /s/a\\011tab\n# impact-type: f\n# impact-inode: 64768:12\n# owner: 2001\n# group: 2002\n'
        printf 'user::rw-\ngroup::r--\t#effective:r--\nother::---\n\n'
        printf '# file: /s/d\n# owner: 0\n# group: 1005\n# flags: -s-\nuser::rwx\ngroup::rwx\nother::---\ndefault:user::rwx\n\n'
    } | impact_sharing_normalize)"
    assert_eq $'0\tf\t64768:12\t2001\t2002\t---\tuser::rw-,group::r--,other::---\t/s/a\\011tab\n1\t?\t?\t0\t1005\t-s-\tuser::rwx,group::rwx,other::---,default:user::rwx\t/s/d' "$output"
}

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------

# The special bits of a getfacl record become the matching chmod arguments.
test_flags_to_chmod() {
    assert_eq 'u-s,g+s,-t' "$(impact_sharing_flags_chmod -s-)"
    assert_eq 'u+s,g-s,+t' "$(impact_sharing_flags_chmod s-t)"
    assert_eq 'u-s,g-s,-t' "$(impact_sharing_flags_chmod ---)"
    assert_eq 'u-s,g-s,-t' "$(impact_sharing_flags_chmod '')"
}

# Flags of a mode.
test_flags_of_a_mode() {
    assert_eq '---' "$(impact_sharing_flags_of_mode 644)"
    assert_eq '-s-' "$(impact_sharing_flags_of_mode 2775)"
    assert_eq 's--' "$(impact_sharing_flags_of_mode 4755)"
    assert_eq '--t' "$(impact_sharing_flags_of_mode 1777)"
    assert_eq 'sst' "$(impact_sharing_flags_of_mode 7777)"
    assert_eq '---' "$(impact_sharing_flags_of_mode 0)"
}

# Number and size texts.
test_number_and_size_texts() {
    assert_eq '0' "$(impact_sharing_number 0)"
    assert_eq '999' "$(impact_sharing_number 999)"
    assert_eq '1,000' "$(impact_sharing_number 1000)"
    assert_eq '12,345,678' "$(impact_sharing_number 12345678)"
    assert_eq '1 file' "$(impact_sharing_count 1 file files)"
    assert_eq '0 files' "$(impact_sharing_count 0 file files)"
    assert_eq '2,500 entries' "$(impact_sharing_count 2500 entry entries)"
    assert_eq '512 B' "$(impact_sharing_bytes 512)"
    assert_eq '1.0 KiB' "$(impact_sharing_bytes 1024)"
    assert_eq '1.5 MiB' "$(impact_sharing_bytes 1572864)"
    assert_eq '3.0 GiB' "$(impact_sharing_bytes 3221225472)"
}

# ----------------------------------------------------------------------------
# impact-clean-images
# ----------------------------------------------------------------------------

# Image names that may reach docker.
test_image_names_that_may_reach_docker() {
    assert_success impact_sharing_valid_image_name example-model:alice
    assert_success impact_sharing_valid_image_name impactncd_germany:alice-example
    assert_success impact_sharing_valid_image_name org/example.model:v1.2
    assert_fails impact_sharing_valid_image_name Example-Model:alice
    assert_fails impact_sharing_valid_image_name example-model
    assert_fails impact_sharing_valid_image_name '-rf:alice'
    assert_fails impact_sharing_valid_image_name 'example-model:alice;rm'
    assert_fails impact_sharing_valid_image_name 'example model:alice'
    assert_fails impact_sharing_valid_image_name 'example-model:$(id)'
    assert_success impact_sharing_valid_image_id "sha256:$(printf '0%.0s' {1..64})"
    assert_fails impact_sharing_valid_image_id 'sha256:abc'
    assert_fails impact_sharing_valid_image_id "--force"
}

# impact-clean-images removes an image only when nobody uses it and its
# account or repository copy is gone.
test_image_decisions() {
    assert_eq 'keep in_use' "$(impact_sharing_image_decision yes removed example-model:bob '')"
    assert_eq 'keep not_impact' "$(impact_sharing_image_decision no invalid weird:tag '')"
    assert_eq 'remove account_removed' "$(impact_sharing_image_decision no removed example-model:bob 'example-model')"
    assert_eq 'remove account_removed' "$(impact_sharing_image_decision no gone example-model:ghost '')"
    assert_eq 'keep copies_unknown' "$(impact_sharing_image_decision no unknown example-model:alice '')"
    assert_eq 'remove unnamed' "$(impact_sharing_image_decision no active '' 'example-model')"
    assert_eq 'keep repository_copy' "$(impact_sharing_image_decision no active example-model:alice 'other example-model')"
    assert_eq 'remove no_repository_copy' "$(impact_sharing_image_decision no active example-model:alice 'example-model-old other')"
    assert_eq 'remove no_repository_copy' "$(impact_sharing_image_decision no active example-model:alice '')"
}

# ----------------------------------------------------------------------------
# impact-export-state
# ----------------------------------------------------------------------------

# Manifest code follows content mode and names only.
test_manifest_code_follows_content_mode_and_names_only() {
    local folder="$TEST_TMP/state" first second
    # shellcheck disable=SC2034
    # Reason for SC2034 (appears unused): the function reads both lists
    # through their names.
    local -a paths=(sub/one two) sources=()
    mkdir -p -- "$folder/sub"
    printf 'a\n' >"$folder/sub/one"
    printf 'b\n' >"$folder/two"
    # shellcheck disable=SC2034
    # Reason for SC2034: as above, the function reads the list by its name.
    sources=("$folder/sub/one" "$folder/two")
    first="$(impact_sharing_manifest_code paths sources)"
    assert_matches "$first" '^[0-9a-f]{64}$'
    touch -d '2001-01-01' -- "$folder/two"
    assert_eq "$first" "$(impact_sharing_manifest_code paths sources)" "code after a change of time only"
    printf 'c\n' >"$folder/two"
    second="$(impact_sharing_manifest_code paths sources)"
    assert_ne "$first" "$second" "code after a change of content"
    chmod 600 -- "$folder/two"
    assert_ne "$second" "$(impact_sharing_manifest_code paths sources)" "code after a change of mode"
    second="$(impact_sharing_manifest_code paths sources)"
    paths=(sub/one three)
    assert_ne "$second" "$(impact_sharing_manifest_code paths sources)" "code after a change of name"
}
