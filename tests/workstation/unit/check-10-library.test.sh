#!/bin/bash
# =============================================================================
# check-10-library.test.sh: unit tests for the health check impact-check
#
# Purpose
#   Tests the pure functions of workstation/lib/impact-check.sh without root
#   rights: sizes in readable form, the kinds of listening addresses, the
#   name patterns of KNOWN_DIRECT_CONTAINERS, the rule for volume names, the
#   reading of "ss" lines, of Docker's quoted fields, of authorized_keys
#   files and of "git status" output, the copy of the SSH configuration
#   without the rules file, and the bookkeeping of the blocks: every block
#   ends with exactly one result, WARN and FAIL come with "What to do", a
#   block that stops unexpectedly is reported as FAIL and the next block
#   still runs, and the exit code follows the worst result. It also checks
#   the options of the command itself (help, wrong options, not root).
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (any account; no root needed)
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter check-10
#
# What it changes on the system
#   Nothing. Temporary files lie in the test's own folder.
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
# are test data or lines of small scripts that must stay exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

setup() {
    load_library
    # shellcheck source=../../../workstation/lib/impact-check.sh
    source "$WORKSTATION_DIR/lib/impact-check.sh"
}

# make_block_command NAME
#   Writes a small command to $TEST_TMP/NAME that loads the library and
#   impact-check.sh and runs the body from standard input.
make_block_command() {
    local file="$TEST_TMP/$1"
    {
        printf '#!/bin/bash\n'
        printf '# %s: a command made by a test\n' "$1"
        printf 'set -euo pipefail\n'
        printf 'IMPACT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"\n'
        printf 'source %q\n' "$WORKSTATION_DIR/lib/impact-common.sh"
        printf 'source %q\n' "$WORKSTATION_DIR/lib/impact-check.sh"
        printf 'impact_init "$IMPACT_SELF"\n'
        cat
    } >"$file"
    chmod 755 "$file"
}

# -----------------------------------------------------------------------------
# Small pure helpers
# -----------------------------------------------------------------------------

# Sizes are printed in the largest fitting unit with at most one decimal
# place.
test_size_text() {
    assert_eq '0 bytes' "$(impact_check_size_text 0)"
    assert_eq '1023 bytes' "$(impact_check_size_text 1023)"
    assert_eq '1 KB' "$(impact_check_size_text 1024)"
    assert_eq '1.5 KB' "$(impact_check_size_text 1536)"
    assert_eq '700 MB' "$(impact_check_size_text 734003200)"
    assert_eq '1.5 GB' "$(impact_check_size_text 1610612736)"
    assert_eq '200 GB' "$(impact_check_size_text 214748364800)"
    assert_eq '7.3 TB' "$(impact_check_size_text 8026531840000)"
    assert_eq '1023 GB' "$(impact_check_size_text 1098437885952)"
    # A leading zero is a decimal number, not an octal one.
    assert_eq '10 bytes' "$(impact_check_size_text 010)"
    assert_eq 'unknown size' "$(impact_check_size_text '')"
    assert_eq 'unknown size' "$(impact_check_size_text '12; rm -rf /')"
    assert_eq 'unknown size' "$(impact_check_size_text -5)"
}

# impact_check_gb_floor rounds bytes down to whole gigabytes, and gives 0 for
# a text that is no number.
test_gb_floor() {
    assert_eq 0 "$(impact_check_gb_floor 1073741823)"
    assert_eq 1 "$(impact_check_gb_floor 1073741824)"
    assert_eq 200 "$(impact_check_gb_floor 214748364800)"
    assert_eq 0 "$(impact_check_gb_floor 'x')"
}

# Listening addresses are sorted into loopback (this machine), all addresses,
# and single network addresses.
test_address_kind() {
    local address
    for address in 127.0.0.1 127.0.0.53 '127.0.0.53%lo' ::1 '[::1]' ::ffff:127.0.0.1; do
        assert_eq loopback "$(impact_check_address_kind "$address")" "$address"
    done
    for address in '' 0.0.0.0 :: '[::]' '*' ::ffff:0.0.0.0; do
        assert_eq all "$(impact_check_address_kind "$address")" "'$address'"
    done
    for address in 192.0.2.10 10.0.0.5 '[fe80::1%eth0]' 2001:db8::1 192.168.1.20; do
        assert_eq network "$(impact_check_address_kind "$address")" "$address"
    done
}

# Name patterns of known direct containers.
test_name_patterns_of_known_direct_containers() {
    assert_success impact_check_name_matches data_preparation_1 'data_preparation_*'
    assert_success impact_check_name_matches prep_a 'other,prep_?'
    assert_success impact_check_name_matches exact 'exact'
    assert_fails impact_check_name_matches prep_ab 'prep_?'
    assert_fails impact_check_name_matches other_data_preparation_1 'data_preparation_*'
    assert_fails impact_check_name_matches anything ''
    # Patterns with other special characters are never used: "[" and "]"
    # would be a character class, "$( )" must stay text.
    assert_fails impact_check_name_matches a '[a-z]'
    assert_fails impact_check_name_matches 'x' '$(touch /tmp/impact-unit-pwned)'
    assert_missing /tmp/impact-unit-pwned
    assert_fails impact_check_name_matches a ' *'
}

# Volume names like impact volumes.
test_volume_names_like_impact_volumes() {
    local name
    # The names of the GUI's volume mode (outputs in Docker volumes): the current
    # form with the container name, and the older form with model and person.
    for name in impactncd_output_Example-Model_alice impactncd_synthpop_Example-Model_alice \
        impactncd_germany_output_alice impactncd_germany_synthpop_alice IMPACTncd_Output_x \
        impactncd_ results_output_2024 x_synthpop_y; do
        assert_success impact_check_volume_like_impact "$name"
    done
    for name in plainvolume output_x synthpop impact_output x_output y_synthpop pgdata; do
        assert_fails impact_check_volume_like_impact "$name"
    done
}

# Listener lines of ss.
test_listener_lines_of_ss() {
    assert_success impact_check_parse_listener 'LISTEN 0      4096       127.0.0.1:8787       0.0.0.0:*    users:(("docker-proxy",pid=1234,fd=4))'
    assert_eq 127.0.0.1 "$IMPACT_CHECK_L_ADDRESS"
    assert_eq 8787 "$IMPACT_CHECK_L_PORT"
    assert_eq 'docker-proxy (process 1234)' "$IMPACT_CHECK_L_PROCESS"
    assert_success impact_check_parse_listener 'LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=1,fd=4),("sshd",pid=7,fd=4))'
    assert_eq '::' "$IMPACT_CHECK_L_ADDRESS"
    assert_eq 22 "$IMPACT_CHECK_L_PORT"
    assert_eq 'sshd (process 1)' "$IMPACT_CHECK_L_PROCESS"
    assert_success impact_check_parse_listener 'LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:*'
    assert_eq 127.0.0.53 "$IMPACT_CHECK_L_ADDRESS"
    assert_eq '' "$IMPACT_CHECK_L_PROCESS"
    assert_success impact_check_parse_listener 'LISTEN 0 5 [fe80::1%eth0]:8790 [::]:*'
    assert_eq fe80::1 "$IMPACT_CHECK_L_ADDRESS"
    assert_success impact_check_parse_listener 'LISTEN 0 5 *:8799 *:*'
    assert_eq '*' "$IMPACT_CHECK_L_ADDRESS"
    assert_eq all "$(impact_check_address_kind "$IMPACT_CHECK_L_ADDRESS")"
    # A program name with control characters is shown safely.
    assert_success impact_check_parse_listener $'LISTEN 0 5 0.0.0.0:8800 0.0.0.0:* users:(("ev\x1bil",pid=9,fd=3))'
    assert_eq 'ev?il (process 9)' "$IMPACT_CHECK_L_PROCESS"
    assert_fails impact_check_parse_listener ''
    assert_fails impact_check_parse_listener 'garbage line'
}

# Quoted fields of docker output are unquoted; Docker's missing-label text
# counts as empty, and escaped characters are refused.
test_quoted_docker_fields() {
    assert_eq alice "$(impact_check_unquote '"alice"')"
    assert_eq '' "$(impact_check_unquote '""')"
    # Docker 29 prints a missing label this way.
    assert_success impact_check_unquote '%!q(<nil>)'
    assert_eq '' "$(impact_check_unquote '%!q(<nil>)')"
    assert_eq 'two words' "$(impact_check_unquote '"two words"')"
    # An escaped character (line break, quote, tab) is no valid name.
    assert_fails impact_check_unquote '"bad\nname"'
    assert_fails impact_check_unquote '"x\"y"'
    assert_fails impact_check_unquote 'alice'
    assert_fails impact_check_unquote '"'
}

# Ports text and reach.
test_ports_text_and_reach() {
    assert_eq '127.0.0.1:8787 -> 8787/tcp' "$(impact_check_ports_text '127.0.0.1|8787|8787/tcp ')"
    assert_eq 'all addresses:8788 -> 8787/tcp' "$(impact_check_ports_text '0.0.0.0|8788|8787/tcp ::|8788|8787/tcp ')"
    assert_eq 'all addresses:8789 -> 8787/tcp' "$(impact_check_ports_text '|8789|8787/tcp')"
    assert_eq '[::1]:8790 -> 8787/tcp, 192.0.2.10:8791 -> 80/tcp' "$(impact_check_ports_text '::1|8790|8787/tcp 192.0.2.10|8791|80/tcp')"
    assert_eq 'no published port' "$(impact_check_ports_text '')"
    assert_eq none "$(impact_check_ports_reach '')"
    assert_eq loopback "$(impact_check_ports_reach '127.0.0.1|8787|8787/tcp ::1|8787|8787/tcp')"
    assert_eq network "$(impact_check_ports_reach '127.0.0.1|8787|8787/tcp 0.0.0.0|8788|8787/tcp')"
    assert_eq network "$(impact_check_ports_reach '192.0.2.10|8791|80/tcp')"
}

# The login keys of an authorized_keys text are counted by type, and comments
# and empty lines do not count.
test_counting_login_keys() {
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        skip "ssh-keygen is not installed here (it is inside the private views)"
    fi
    local key_dir="$TEST_TMP/keys" one two text
    mkdir -p "$key_dir"
    ssh-keygen -q -t ed25519 -N '' -C one -f "$key_dir/one"
    ssh-keygen -q -t ed25519 -N '' -C two -f "$key_dir/two"
    one="$(cat "$key_dir/one.pub")"
    two="$(cat "$key_dir/two.pub")"
    text="# a comment line
$one

from=\"192.0.2.1\" $two
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ== old-key
$two"
    impact_check_count_keys "$text"
    assert_eq 2 "$IMPACT_CHECK_KEYS_ED25519" "plain ed25519 lines"
    assert_eq 2 "$IMPACT_CHECK_KEYS_OTHER" "lines with options or another type"
    assert_eq "$(ssh-keygen -l -E sha256 -f "$key_dir/one.pub" | awk '{ print $2 }')" "${IMPACT_CHECK_KEY_FPS[0]}"
    impact_check_count_keys ''
    assert_eq 0 "$IMPACT_CHECK_KEYS_ED25519"
    assert_eq 0 "$IMPACT_CHECK_KEYS_OTHER"
}

# The summary of "git status" counts untracked and changed files, also for
# renamed files and names with line breaks.
test_git_status_output() {
    # Five entries: untracked, modified, renamed (followed by its old name),
    # an untracked name with a line break, an ignored one.
    impact_check_porcelain_summary < <(printf '%s\0' '?? notes.txt' ' M README.md' 'R  new.R' 'old.R' $'?? odd\nname.csv' '!! ignored.tmp')
    assert_eq 2 "$IMPACT_CHECK_UNTRACKED"
    assert_eq 2 "$IMPACT_CHECK_CHANGED"
    assert_eq 'notes.txt' "${IMPACT_CHECK_UNTRACKED_NAMES[0]}"
    assert_eq 'odd?name.csv' "${IMPACT_CHECK_UNTRACKED_NAMES[1]}"
    impact_check_porcelain_summary </dev/null
    assert_eq 0 "$IMPACT_CHECK_UNTRACKED"
    assert_eq 0 "$IMPACT_CHECK_CHANGED"
    # At most five names are kept.
    impact_check_porcelain_summary < <(printf '?? f%s\0' 1 2 3 4 5 6 7)
    assert_eq 7 "$IMPACT_CHECK_UNTRACKED"
    assert_eq 5 "${#IMPACT_CHECK_UNTRACKED_NAMES[@]}"
}

# Ssh configuration without the rules file.
test_ssh_configuration_without_the_rules_file() {
    local base="$TEST_TMP/etc-ssh" result
    mkdir -p "$base/sshd_config.d"
    : >"$base/sshd_config.d/10-local.conf"
    : >"$base/sshd_config.d/60-impact.conf"
    : >"$base/sshd_config.d/70-other.conf"
    cat >"$base/sshd_config" <<END
# a comment
Include $base/sshd_config.d/*.conf
include=sshd_config.d/*.conf
Include /elsewhere/x.conf $base/sshd_config.d/60-impact.conf
Port 22
Match User admin
    PasswordAuthentication yes
END
    result="$(impact_check_config_without_rules "$base/sshd_config" "$base/sshd_config.d/60-impact.conf" "$base")"
    assert_contains "$result" "Include $base/sshd_config.d/10-local.conf $base/sshd_config.d/70-other.conf
Include $base/sshd_config.d/10-local.conf $base/sshd_config.d/70-other.conf
Include /elsewhere/x.conf
Port 22"
    assert_not_contains "$result" '60-impact.conf'
    assert_contains "$result" '# a comment'
    assert_contains "$result" '    PasswordAuthentication yes'
    # Only the rules file in the folder: the Include line becomes a comment.
    rm -f "$base/sshd_config.d/10-local.conf" "$base/sshd_config.d/70-other.conf"
    printf 'Include %s/sshd_config.d/*.conf\n' "$base" >"$base/sshd_config"
    assert_eq '# (impact-check: the rules file is left out here)' \
        "$(impact_check_config_without_rules "$base/sshd_config" "$base/sshd_config.d/60-impact.conf" "$base")"
}

# Mode writable by others.
test_mode_writable_by_others() {
    assert_success impact_check_mode_writable_by_others 775
    assert_success impact_check_mode_writable_by_others 757
    assert_success impact_check_mode_writable_by_others 2770
    assert_fails impact_check_mode_writable_by_others 755
    assert_fails impact_check_mode_writable_by_others 2750
    assert_fails impact_check_mode_writable_by_others 700
    # A mode that cannot be read counts as unsafe.
    assert_success impact_check_mode_writable_by_others ''
    assert_success impact_check_mode_writable_by_others 'abc'
}

# Entry facts never follow links.
test_entry_facts_never_follow_links() {
    mkdir "$TEST_TMP/folder"
    : >"$TEST_TMP/file"
    ln -s "$TEST_TMP/folder" "$TEST_TMP/link"
    impact_check_entry_facts "$TEST_TMP/folder"
    assert_eq folder "$IMPACT_CHECK_E_TYPE"
    impact_check_entry_facts "$TEST_TMP/file"
    assert_eq file "$IMPACT_CHECK_E_TYPE"
    impact_check_entry_facts "$TEST_TMP/link"
    assert_eq link "$IMPACT_CHECK_E_TYPE"
    impact_check_entry_facts "$TEST_TMP/missing"
    assert_eq missing "$IMPACT_CHECK_E_TYPE"
    assert_eq "$(id -un)" "$(impact_check_entry_facts "$TEST_TMP/file"; printf '%s' "$IMPACT_CHECK_E_OWNER")"
}

# -----------------------------------------------------------------------------
# Blocks and summary
# -----------------------------------------------------------------------------

# Blocks end with one result and what to do.
test_blocks_end_with_one_result_and_what_to_do() {
    make_block_command blocks <<'END'
good() { impact_check_ok "fine"; impact_check_info "a fact"; }
warning() {
    impact_check_warn "first warning" "do one thing"
    impact_check_warn "second warning" "do one thing"
    impact_check_ok "fine afterwards"
}
failure() { impact_check_fail "broken" "repair it"; impact_check_warn "also this" "and this"; }
crash() { impact_check_ok "before"; false; impact_check_ok "never printed"; }
silent_unset() { printf '%s\n' "$never_set_variable"; }
impact_check_run_block 'Good block' good
impact_check_run_block 'Warning block' warning
impact_check_run_block 'Failing block' failure
impact_check_run_block 'Crashing block' crash
impact_check_run_block 'Unset variable' silent_unset
impact_check_run_block 'Good again' good
impact_check_print_summary
exit "$IMPACT_CHECK_EXIT"
END
    run_cmd "$TEST_TMP/blocks"
    assert_status 2
    assert_output_contains $'Block 1: Good block\n    OK: fine\n    a fact\n  Result of block 1: OK'
    assert_output_contains $'    WARNING: second warning\n    OK: fine afterwards\n  What to do:\n    - do one thing\n  Result of block 2: WARN'
    assert_output_contains $'  What to do:\n    - repair it\n    - and this\n  Result of block 3: FAIL'
    assert_output_contains $'    OK: before\n    FAIL: This block stopped before it finished (exit code 1)'
    assert_output_not_contains 'never printed'
    assert_output_contains '  Result of block 4: FAIL'
    assert_output_contains '  Result of block 5: FAIL'
    # The block after the unexpected end still runs.
    assert_output_contains $'Block 6: Good again\n    OK: fine'
    assert_output_contains '  Result of block 6: OK'
    # The summary lines, built with the same column widths as the command.
    assert_output_contains "$(printf '  %2d  %-44s %s\n' 1 'Good block' OK 2 'Warning block' WARN 3 'Failing block' FAIL)"
    assert_output_contains '  6 blocks: 2 OK, 1 WARN, 3 FAIL.'
    assert_output_contains 'Overall result: FAIL (exit code 2).'
    # Exactly one result line per block.
    assert_eq 6 "$(printf '%s\n' "$RUN_OUTPUT" | grep -c '^  Result of block ')"
}

# Exit code follows the worst result.
test_exit_code_follows_the_worst_result() {
    make_block_command only-ok <<'END'
good() { impact_check_ok "fine"; }
impact_check_run_block 'One' good
impact_check_run_block 'Two' good
impact_check_print_summary
exit "$IMPACT_CHECK_EXIT"
END
    run_cmd "$TEST_TMP/only-ok"
    assert_status 0
    assert_output_contains 'Overall result: OK (exit code 0). Every block is in order.'
    make_block_command with-warn <<'END'
good() { impact_check_ok "fine"; }
warning() { impact_check_warn "careful" ""; }
impact_check_run_block 'One' good
impact_check_run_block 'Two' warning
impact_check_print_summary
exit "$IMPACT_CHECK_EXIT"
END
    run_cmd "$TEST_TMP/with-warn"
    assert_status 1
    assert_output_contains 'Overall result: WARN (exit code 1).'
    # A warning without its own text gets the general next step.
    assert_output_contains '    - Read the line above and correct what it names.'
}

# Note about default values appears once per block.
test_note_about_default_values_appears_once_per_block() {
    make_block_command guess <<'END'
IMPACT_CHECK_CONF_STATE='missing'
IMPACT_CONF[SHARED_GROUP]=impact
IMPACT_CONF[PORT_MIN]=8787
IMPACT_CONF[PORT_MAX]=8830
twice() { impact_check_note_guess; impact_check_note_guess; impact_check_ok "rest"; }
impact_check_run_block 'One' twice
impact_check_run_block 'Two' twice
impact_check_print_summary
END
    run_cmd "$TEST_TMP/guess"
    assert_eq 2 "$(printf '%s\n' "$RUN_OUTPUT" | grep -c 'Without a usable settings file (block 4) this block works with default values (group impact, ports 8787 to 8830).')"
    assert_output_contains '  Result of block 1: WARN'
    assert_output_contains '  Result of block 2: WARN'
}

# -----------------------------------------------------------------------------
# The command's options (no root needed for these)
# -----------------------------------------------------------------------------

# Help of the command.
test_help_of_the_command() {
    run_cmd "$WORKSTATION_DIR/bin/impact-check" --help
    assert_status 0
    assert_output_contains 'impact-check: health check of the IMPACT workstation'
    assert_output_contains '--mask'
    assert_output_contains '--shared-roots <paths>'
    assert_output_contains 'What it changes on the system'
    assert_output_not_contains 'Reading help'
}

# Wrong options are usage errors.
test_wrong_options_are_usage_errors() {
    run_cmd "$WORKSTATION_DIR/bin/impact-check" --dry-run
    assert_status 2
    assert_output_contains "Unknown option '--dry-run'"
    run_cmd "$WORKSTATION_DIR/bin/impact-check" something
    assert_status 2
    run_cmd "$WORKSTATION_DIR/bin/impact-check" --mask --mask=1
    assert_status 2
    run_cmd "$WORKSTATION_DIR/bin/impact-check" --shared-roots $'/mnt/a\tb'
    assert_status 2
    assert_output_contains 'control character'
}

# The command needs root.
test_the_command_needs_root() {
    if ((EUID == 0)); then
        skip "this test needs an account without root rights (the system tests cover root)"
    fi
    run_cmd "$WORKSTATION_DIR/bin/impact-check"
    assert_status 2
    assert_output_contains 'impact-check must run with administrator rights.'
    # This copy is not installed, so the hint names it by its path, the way
    # it can be typed ("sudo impact-check" would find no command).
    assert_output_contains '/bin/impact-check ...'
    assert_output_not_contains 'sudo impact-check ...'
    assert_output_not_contains 'Block 1'
}
