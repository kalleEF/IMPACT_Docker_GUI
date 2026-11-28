#!/bin/bash
# =============================================================================
# 70-command-flow.test.sh: unit tests for the parts of impact-common.sh that
# shape every command (options, dry run, summary, end-of-command work)
#
# Purpose
#   Each test writes a small command into the temporary folder, runs it, and
#   checks its output and exit code. This proves: option parsing with all its
#   refusals, --help, the dry run that prints the same steps and runs
#   nothing, the summary, the report after an early stop, the clean-up of
#   temporary files, the handlers that run at the end, the result line for
#   the GUI, and the confirmation prompt.
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (no special rights needed)
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter 70-command
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
# are test data, or lines of small scripts that a test writes. They must stay
# exactly as written.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/testlib.sh"

# make_command NAME
#   Writes a small command to $TEST_TMP/NAME. The body of the command comes
#   from standard input; the standard first lines of every IMPACT command are
#   put in front of it.
make_command() {
    local file="$TEST_TMP/$1"
    {
        printf '#!/bin/bash\n'
        printf '# %s: a command made by a test\n' "$1"
        printf '#\n# Usage\n#   %s [options]\n' "$1"
        printf '# ==========================================\n'
        printf 'set -euo pipefail\n'
        printf 'IMPACT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"\n'
        printf 'source %q\n' "$WORKSTATION_DIR/lib/impact-common.sh"
        printf 'impact_init "$IMPACT_SELF"\n'
        cat
    } >"$file"
    chmod 755 "$file"
}

# ----------------------------------------------------------------------------
# Options
# ----------------------------------------------------------------------------

# options_command: a command that prints what the parser understood.
options_command() {
    make_command show-options <<'END'
impact_parse_args 'dry-run yes existing' 'account uid' 'storage' "$@"
for name in dry-run yes existing account uid storage; do
    if impact_opt_given "$name"; then
        printf 'opt %s=[%s]\n' "$name" "$(impact_opt "$name")"
    fi
done
printf 'default=[%s]\n' "$(impact_opt uid 'none')"
impact_opt_list storage roots
printf 'storage count=%s\n' "${#roots[@]}"
for argument in "${IMPACT_ARGS[@]}"; do
    printf 'arg=[%s]\n' "$argument"
done
printf 'dry=%s yes=%s\n' "$IMPACT_DRY_RUN" "$IMPACT_ASSUME_YES"
END
}

# Options flags values lists and arguments.
test_options_flags_values_lists_and_arguments() {
    options_command
    run_cmd "$TEST_TMP/show-options" first --existing --account alice --uid=1005 second \
        --storage /mnt/disk_a/shared --storage=/mnt/disk_b/shared third
    assert_status 0
    assert_output_contains 'opt existing=[1]'
    assert_output_contains 'opt account=[alice]'
    assert_output_contains 'opt uid=[1005]'
    assert_output_contains 'storage count=2'
    assert_output_contains 'arg=[first]'
    assert_output_contains 'arg=[second]'
    assert_output_contains 'arg=[third]'
    assert_output_contains 'dry=0 yes=0'
    assert_output_not_contains 'opt dry-run'
}

# Options default and empty value.
test_options_default_and_empty_value() {
    options_command
    run_cmd "$TEST_TMP/show-options"
    assert_status 0
    assert_output_contains 'default=[none]'
    assert_output_contains 'storage count=0'
    # An empty value is a value ("" removes a setting).
    run_cmd "$TEST_TMP/show-options" --account ''
    assert_status 0
    assert_output_contains 'opt account=[]'
    run_cmd "$TEST_TMP/show-options" --account=
    assert_output_contains 'opt account=[]'
    # A value may contain "=" and blanks.
    run_cmd "$TEST_TMP/show-options" --account='a=b c'
    assert_output_contains 'opt account=[a=b c]'
}

# Options dry run and yes set the switches.
test_options_dry_run_and_yes_set_the_switches() {
    options_command
    run_cmd "$TEST_TMP/show-options" --dry-run --yes
    assert_status 0
    assert_output_contains 'dry=1 yes=1'
    assert_output_contains 'DRY RUN'
    assert_output_contains 'Nothing is changed'
}

# Options double dash ends the options.
test_options_double_dash_ends_the_options() {
    options_command
    run_cmd "$TEST_TMP/show-options" --account alice -- --existing -x --help
    assert_status 0
    assert_output_contains 'arg=[--existing]'
    assert_output_contains 'arg=[-x]'
    assert_output_contains 'arg=[--help]'
    assert_output_not_contains 'opt existing'
}

# Options refusals end with exit code 2.
test_options_refusals_end_with_exit_code_2() {
    options_command
    local -a bad_calls=(
        '--unknown'
        '--account'
        '--account --existing'
        '--existing=1'
        '--account a --account b'
        '-x'
        '-rf'
        '--Account alice'
        '--account_x alice'
        '--='
    )
    local call
    for call in "${bad_calls[@]}"; do
        # shellcheck disable=SC2086
        # Reason for SC2086 (unquoted variable): each entry holds several
        # arguments that must be split at the blanks.
        run_cmd "$TEST_TMP/show-options" $call
        if [[ "$RUN_STATUS" != '2' ]]; then
            show_run
            fail "expected exit code 2 for: $call"
        fi
        assert_output_contains 'ERROR:'
        assert_output_contains '--help'
        assert_output_not_contains 'dry='
    done
}

# Options control characters are refused.
test_options_control_characters_are_refused() {
    options_command
    run_cmd "$TEST_TMP/show-options" $'alice\nresult: ok'
    assert_status 2
    assert_output_contains 'control character'
    run_cmd "$TEST_TMP/show-options" --account $'a\tb'
    assert_status 2
    run_cmd "$TEST_TMP/show-options" --account $'a\e[31m'
    assert_status 2
    run_cmd "$TEST_TMP/show-options" -- $'after\rdash'
    assert_status 2
}

# Help prints the header and wins over other options.
test_help_prints_the_header_and_wins_over_other_options() {
    options_command
    run_cmd "$TEST_TMP/show-options" --unknown --help
    assert_status 0
    assert_output_contains 'show-options: a command made by a test'
    assert_output_contains 'Usage'
    assert_output_not_contains '====='
    assert_output_not_contains 'set -euo'
    assert_output_not_contains '#!/bin/bash'
}

# impact_require_arg_count stops with exit code 2 for too few or too many
# arguments.
test_argument_count() {
    make_command count-arguments <<'END'
impact_parse_args '' '' '' "$@"
impact_require_arg_count 1 2
echo "accepted ${#IMPACT_ARGS[@]}"
END
    run_cmd "$TEST_TMP/count-arguments"
    assert_status 2
    assert_output_contains 'An argument is missing'
    run_cmd "$TEST_TMP/count-arguments" one
    assert_status 0
    run_cmd "$TEST_TMP/count-arguments" one two
    assert_status 0
    assert_output_contains 'accepted 2'
    run_cmd "$TEST_TMP/count-arguments" one two three
    assert_status 2
    assert_output_contains "'three'"
}

# ----------------------------------------------------------------------------
# Dry run, steps and summary
# ----------------------------------------------------------------------------

# steps_command: a command with two changing steps and one that is already
# done.
steps_command() {
    make_command do-steps <<END
impact_parse_args 'dry-run' '' '' "\$@"
impact_step "First part"
impact_do "Create the file one" touch "$TEST_TMP/one"
impact_undo "Remove the file one: rm $TEST_TMP/one"
impact_ok "The folder exists already."
impact_step "Second part"
impact_do --transient "Test something that leaves nothing behind" touch "$TEST_TMP/transient"
impact_do "Create the file two" touch "$TEST_TMP/two"
impact_warn "A warning for the reader."
impact_summary
END
}

# Real run executes and summarises.
test_real_run_executes_and_summarises() {
    steps_command
    run_cmd "$TEST_TMP/do-steps"
    assert_status 0
    assert_exists "$TEST_TMP/one"
    assert_exists "$TEST_TMP/two"
    assert_exists "$TEST_TMP/transient"
    assert_output_contains 'Step 1: First part'
    assert_output_contains 'Step 2: Second part'
    assert_output_contains '  + Create the file one'
    assert_output_contains 'What changed:'
    assert_output_contains 'How to undo:'
    assert_output_contains '  - Remove the file one'
    assert_output_contains 'Warnings printed above: 1'
    assert_output_not_contains '[dry run]'
    # The step that leaves nothing behind is printed once (as a step) and is
    # absent from "What changed".
    assert_eq 1 "$(printf '%s\n' "$RUN_OUTPUT" | grep -c 'Test something')"
    assert_eq 2 "$(printf '%s\n' "$RUN_OUTPUT" | grep -c 'Create the file one')"
}

# Dry run prints the same steps and changes nothing.
test_dry_run_prints_the_same_steps_and_changes_nothing() {
    steps_command
    run_cmd "$TEST_TMP/do-steps"
    local real_output="$RUN_OUTPUT"
    rm -f "$TEST_TMP/one" "$TEST_TMP/two" "$TEST_TMP/transient"
    run_cmd "$TEST_TMP/do-steps" --dry-run
    assert_status 0
    assert_missing "$TEST_TMP/one"
    assert_missing "$TEST_TMP/two"
    assert_missing "$TEST_TMP/transient"
    assert_output_contains '  + [dry run] Create the file one'
    assert_output_contains '  + [dry run] Create the file two'
    assert_output_contains 'Dry run: nothing was changed. A real run would do this:'
    assert_output_contains 'How to undo it afterwards:'
    # Same steps, same order, same words: compare the step lines of both
    # runs after removing the dry-run mark.
    local real_steps dry_steps
    real_steps="$(printf '%s\n' "$real_output" | grep -E '^(Step|  \+ )')"
    dry_steps="$(printf '%s\n' "$RUN_OUTPUT" | grep -E '^(Step|  \+ )' | sed -e 's/\[dry run\] //')"
    assert_eq "$real_steps" "$dry_steps" "step lines of the real run and of the dry run"
}

# Nothing to do is said plainly.
test_nothing_to_do_is_said_plainly() {
    make_command nothing <<'END'
impact_parse_args 'dry-run' '' '' "$@"
impact_step "Check"
impact_ok "Everything is in place."
impact_summary
END
    run_cmd "$TEST_TMP/nothing"
    assert_status 0
    assert_output_contains 'Nothing to do: everything is already in the requested state. Nothing was changed.'
    run_cmd "$TEST_TMP/nothing" --dry-run
    assert_status 0
    assert_output_contains 'A real run would change nothing either'
}

# Failing step reports what ran before.
test_failing_step_reports_what_ran_before() {
    make_command fails-midway <<END
impact_parse_args 'dry-run' '' '' "\$@"
impact_do "Create the file one" touch "$TEST_TMP/one"
impact_undo "Remove the file one"
impact_do "Do something impossible" false
impact_do "Create the file two" touch "$TEST_TMP/two"
impact_summary
END
    run_cmd "$TEST_TMP/fails-midway"
    assert_status 1
    assert_exists "$TEST_TMP/one"
    assert_missing "$TEST_TMP/two"
    assert_output_contains 'This step failed (exit code 1): Do something impossible'
    assert_output_contains 'stopped before it finished'
    assert_output_contains 'These steps had already run:'
    assert_output_contains '  + Create the file one'
    assert_output_contains '  - Remove the file one'
    assert_output_not_contains 'What changed:'
}

# Die prints cause and next step.
test_die_prints_cause_and_next_step() {
    make_command dies <<'END'
impact_parse_args '' '' '' "$@"
impact_die "$IMPACT_EXIT_CONFLICT" "The target exists already." "Choose another name."
echo "not reached"
END
    run_cmd "$TEST_TMP/dies"
    assert_status 4
    assert_output_contains 'ERROR: The target exists already.'
    assert_output_contains 'What to do: Choose another name.'
    assert_output_not_contains 'not reached'
}

# Exit codes have the agreed values.
test_exit_codes_have_the_agreed_values() {
    load_library
    assert_eq '0 1 2 3 4 5 6' "$IMPACT_EXIT_OK $IMPACT_EXIT_FAILED $IMPACT_EXIT_USAGE $IMPACT_EXIT_NOT_PREPARED $IMPACT_EXIT_CONFLICT $IMPACT_EXIT_NO_ACCESS $IMPACT_EXIT_NETWORK"
}

# ----------------------------------------------------------------------------
# End-of-command work
# ----------------------------------------------------------------------------

# Temporary files are removed at the end.
test_temporary_files_are_removed_at_the_end() {
    make_command temp-files <<END
impact_parse_args '' 'how' '' "\$@"
impact_mktemp_file
echo "\$IMPACT_TMP" >"$TEST_TMP/temp-file-path"
impact_mktemp_dir
echo "\$IMPACT_TMP" >"$TEST_TMP/temp-dir-path"
touch "\$IMPACT_TMP/inside"
impact_mktemp_file_in "$TEST_TMP"
echo "\$IMPACT_TMP" >"$TEST_TMP/temp-local-path"
[[ -f "\$(cat "$TEST_TMP/temp-file-path")" && -d "\$(cat "$TEST_TMP/temp-dir-path")" ]] || exit 9
case "\$(impact_opt how ok)" in
    die) impact_die 1 "stop" "" ;;
    false) false ;;
    *) ;;
esac
END
    local how
    for how in ok die false; do
        run_cmd "$TEST_TMP/temp-files" --how "$how"
        if [[ "$how" == 'ok' ]]; then
            assert_status 0
        else
            assert_status 1
        fi
        assert_missing "$(cat "$TEST_TMP/temp-file-path")"
        assert_missing "$(cat "$TEST_TMP/temp-dir-path")"
        assert_missing "$(cat "$TEST_TMP/temp-local-path")"
        assert_eq "$TEST_TMP" "$(dirname "$(cat "$TEST_TMP/temp-local-path")")"
    done
}

# Temporary files are private.
test_temporary_files_are_private() {
    make_command temp-mode <<'END'
impact_mktemp_file
stat -c 'file %a' "$IMPACT_TMP"
impact_mktemp_dir
stat -c 'dir %a' "$IMPACT_TMP"
END
    run_cmd "$TEST_TMP/temp-mode"
    assert_status 0
    assert_output_contains 'file 600'
    assert_output_contains 'dir 700'
}

# Exit handlers run in reverse order also after errors.
test_exit_handlers_run_in_reverse_order_also_after_errors() {
    make_command handlers <<END
first_handler() { echo "first handler, code \$1" >>"$TEST_TMP/handler-log"; }
second_handler() { echo "second handler, code \$1" >>"$TEST_TMP/handler-log"; }
impact_on_exit first_handler
impact_on_exit second_handler
impact_die 5 "no access" ""
END
    run_cmd "$TEST_TMP/handlers"
    assert_status 5
    assert_eq $'second handler, code 5\nfirst handler, code 5' "$(cat "$TEST_TMP/handler-log")"
}

# Signal cleans up and ends with code 143.
test_signal_cleans_up_and_ends_with_code_143() {
    # The signal TERM is used here. bash starts background commands of a
    # script with the signal INT (Ctrl+C) switched off, so INT cannot be
    # tried this way; the command handles both signals with the same code.
    make_command waits <<END
impact_mktemp_file
echo "\$IMPACT_TMP" >"$TEST_TMP/temp-file-path"
sleep 30 &
echo "\$!" >"$TEST_TMP/sleep-pid"
echo started >"$TEST_TMP/started"
wait "\$(cat "$TEST_TMP/sleep-pid")"
END
    "$TEST_TMP/waits" >"$TEST_TMP/waits-output" 2>&1 &
    local pid=$!
    # "_" as the loop variable: the value itself is not needed.
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [[ -e "$TEST_TMP/started" ]] && break
        sleep 0.2
    done
    assert_exists "$TEST_TMP/started"
    kill -TERM "$pid"
    local status=0
    wait "$pid" || status=$?
    # End the sleep that the command left behind (exactly that process).
    kill "$(cat "$TEST_TMP/sleep-pid")" 2>/dev/null || true
    assert_eq 143 "$status" "exit code after the signal TERM"
    assert_missing "$(cat "$TEST_TMP/temp-file-path")"
    assert_file_contains "$TEST_TMP/waits-output" 'was interrupted'
}

# Result line is the last line.
test_result_line_is_the_last_line() {
    make_command result-ok <<'END'
impact_result_enable
impact_parse_args '' '' '' "$@"
impact_say "working"
impact_result_set /home/alice/Repositories/Example-Model cloned
END
    run_cmd "$TEST_TMP/result-ok"
    assert_status 0
    assert_eq 'IMPACT_RESULT status=ok code=0 path=/home/alice/Repositories/Example-Model reason=cloned' \
        "$(printf '%s\n' "$RUN_OUTPUT" | tail -n 1)"

    make_command result-error <<'END'
impact_result_enable
impact_parse_args '' '' '' "$@"
impact_die_reason "$IMPACT_EXIT_NO_ACCESS" key_refused "GitHub refused the key." "Contact the administrator."
END
    run_cmd "$TEST_TMP/result-error"
    assert_status 5
    assert_eq 'IMPACT_RESULT status=error code=5 path= reason=key_refused' "$(printf '%s\n' "$RUN_OUTPUT" | tail -n 1)"
}

# Result line has a default reason per exit code.
test_result_line_has_a_default_reason_per_exit_code() {
    make_command result-default <<'END'
impact_result_enable
impact_parse_args '' 'code' '' "$@"
exit "$(impact_opt code 0)"
END
    local -A expected=([0]=ok [1]=failed [2]=usage [3]=not_prepared [4]=exists [5]=no_access [6]=network)
    local code
    for code in 0 1 2 3 4 5 6; do
        run_cmd "$TEST_TMP/result-default" --code "$code"
        assert_status "$code"
        assert_output_contains "reason=${expected[$code]}"
    done
    # A usage error also ends with the result line.
    run_cmd "$TEST_TMP/result-default" --unknown
    assert_status 2
    assert_eq 'IMPACT_RESULT status=error code=2 path= reason=usage' "$(printf '%s\n' "$RUN_OUTPUT" | tail -n 1)"
}

# Result line drops unsafe characters.
test_result_line_drops_unsafe_characters() {
    make_command result-unsafe <<'END'
impact_result_enable
impact_result_set '/home/alice/x y;$(id)' 'two words=1'
END
    run_cmd "$TEST_TMP/result-unsafe"
    assert_eq 'IMPACT_RESULT status=ok code=0 path=/home/alice/xyid reason=twowords1' "$(printf '%s\n' "$RUN_OUTPUT" | tail -n 1)"
}

# ----------------------------------------------------------------------------
# Root checks, confirmation, log
# ----------------------------------------------------------------------------

# An administrator command stops without root and a user command stops with
# root, each with exit code 2; --help works for everyone.
test_root_checks() {
    make_command needs-root <<'END'
impact_parse_args '' '' '' "$@"
impact_require_root
echo "is root"
END
    make_command refuses-root <<'END'
impact_result_enable
impact_parse_args '' '' '' "$@"
impact_require_not_root
echo "is a person"
END
    if ((EUID == 0)); then
        run_cmd "$TEST_TMP/needs-root"
        assert_status 0
        run_cmd "$TEST_TMP/refuses-root"
        assert_status 2
        assert_output_contains 'impact-give-repo'
        assert_output_contains 'reason=run_as_root'
    else
        run_cmd "$TEST_TMP/needs-root"
        assert_status 2
        assert_output_contains 'sudo'
        # The command is not installed: the hint names it by its path.
        assert_output_contains "needs-root ..."
        run_cmd "$TEST_TMP/refuses-root"
        assert_status 0
    fi
    # --help works without root rights in both cases.
    run_cmd "$TEST_TMP/needs-root" --help
    assert_status 0
}

# The root hint names the command the way it can be typed: a script inside
# the current folder as ./name, any other script that is not installed with
# its full path (quoted when it holds unusual characters). "sudo install.sh"
# would fail with "command not found".
test_typed_name_of_a_script_that_is_not_installed() {
    load_library
    mkdir -p "$TEST_TMP/unpacked/bin"
    IMPACT_CMD='install.sh'
    IMPACT_SELF="$TEST_TMP/unpacked/install.sh"
    cd -- "$TEST_TMP/unpacked" || fail "cannot enter $TEST_TMP/unpacked"
    assert_eq './install.sh' "$(impact_typed_name)"
    IMPACT_CMD='impact-check'
    IMPACT_SELF="$TEST_TMP/unpacked/bin/impact-check"
    assert_eq './bin/impact-check' "$(impact_typed_name)"
    cd / || fail "cannot enter /"
    assert_eq "$TEST_TMP/unpacked/bin/impact-check" "$(impact_typed_name)"
    IMPACT_CMD='uninstall.sh'
    IMPACT_SELF="/srv/my folder/uninstall.sh"
    assert_eq "'/srv/my folder/uninstall.sh'" "$(impact_typed_name)"
}

# Confirm with yes dry run and without terminal.
test_confirm_with_yes_dry_run_and_without_terminal() {
    make_command asks <<'END'
impact_parse_args 'dry-run yes' '' '' "$@"
if impact_confirm "Really remove everything?"; then
    echo "confirmed"
else
    echo "not confirmed"
    exit 1
fi
END
    run_cmd "$TEST_TMP/asks" --yes
    assert_status 0
    assert_output_contains 'Really remove everything?'
    assert_output_contains 'Answered by the option --yes'
    assert_output_contains 'confirmed'
    run_cmd "$TEST_TMP/asks" --dry-run
    assert_status 0
    assert_output_contains 'A real run asks here: Really remove everything?'
    # No terminal: setsid starts the command without one. The answer must be
    # "no", with an explanation, and never a wait for input.
    run_cmd timeout 20 setsid --wait "$TEST_TMP/asks"
    assert_status 1
    assert_output_contains 'no terminal is available'
    assert_output_contains '--yes'
    assert_output_contains 'not confirmed'
}

# A signal that arrives while an impact_do step runs: bash handles it when
# the step's program has ended, so the change may be made. The report at
# the end names that step as "may have finished", next to the steps that
# had run before.
test_a_step_that_was_running_at_a_signal_is_reported() {
    make_command interrupted <<'END'
impact_parse_args 'dry-run' '' '' "$@"
impact_do "Make the first change" true
# The step's program sends TERM to the command itself ($PPID of the inner
# bash) and finishes its work.
impact_do "Make the second change" bash -c 'kill -TERM "$PPID"; sleep 0.2; echo done-inside'
impact_do "Make the third change" true
impact_summary
END
    run_cmd "$TEST_TMP/interrupted"
    assert_status 143
    assert_output_contains 'was interrupted (signal TERM)'
    assert_output_contains 'These steps had already run:'
    assert_output_contains '  + Make the first change'
    assert_output_contains 'This step was running when the command stopped and may have finished:'
    assert_output_contains '  ? Make the second change'
    assert_output_not_contains 'Make the third change'
}

# Signals held around a step and its undo line (impact_signals_hold, as
# impact-add-user does around useradd and the account record): a request to
# end (TERM) to the command, and one to the program itself, arrive while the
# step's program runs. The program ignores its signal and finishes
# (impact_run_uninterrupted); the command stops at impact_signals_release.
# The report then lists the step as done, with its undo line, and never as
# "may have finished"; the step after the release does not run.
test_held_signals_take_effect_after_the_step_and_its_undo_line() {
    make_command holds <<'END'
impact_parse_args 'dry-run' '' '' "$@"
impact_signals_hold
impact_do "Make the first change" impact_run_uninterrupted bash -c 'kill -TERM "$PPID"; kill -TERM "$$"; sleep 0.3; echo "program finished"'
impact_undo "Undo the first change: sudo undo-it"
impact_signals_release
impact_do "Make the second change" true
impact_summary
END
    run_cmd "$TEST_TMP/holds"
    assert_status 143
    assert_output_contains 'program finished'
    assert_output_contains 'was interrupted (signal TERM)'
    assert_output_contains 'These steps had already run:'
    assert_output_contains '  + Make the first change'
    assert_output_contains 'How to undo them:'
    assert_output_contains 'Undo the first change: sudo undo-it'
    assert_output_not_contains 'may have finished'
    assert_output_not_contains 'Make the second change'
}

# Without a signal, impact_signals_release changes nothing: the command
# goes on, and a signal after the release takes effect at once again.
test_release_without_a_signal_lets_the_command_go_on() {
    make_command holds-quietly <<'END'
impact_parse_args 'dry-run' '' '' "$@"
impact_signals_hold
impact_do "Make the first change" true
impact_signals_release
impact_do "Make the second change" bash -c 'kill -TERM "$PPID"; sleep 0.2'
impact_do "Make the third change" true
impact_summary
END
    run_cmd "$TEST_TMP/holds-quietly"
    assert_status 143
    assert_output_contains '  + Make the first change'
    assert_output_contains '  ? Make the second change'
    assert_output_not_contains 'Make the third change'
}

# A signal while a shell function runs whose error channel goes into a file
# ("step 2>file", as impact-get-repo does for git): bash applies such a
# redirection in the command itself, so the end-of-command messages would
# land in the file. The library writes them to its own copies of the
# channels, so the reader sees the message, the steps and the result line.
test_signal_during_a_redirected_function_reaches_the_reader() {
    make_command redirected <<END
impact_result_enable
impact_parse_args '' '' '' "\$@"
impact_mktemp_file
error_file="\$IMPACT_TMP"
echo "\$error_file" >"$TEST_TMP/error-file-path"
works() {
    echo "message of the tool" >&2
    kill -TERM "\$\$"
    sleep 0.2
}
run_step() {
    works 2>"\$error_file"
}
impact_do "Make the change" run_step
impact_summary
END
    run_cmd "$TEST_TMP/redirected"
    assert_status 143
    assert_output_contains 'was interrupted (signal TERM)'
    assert_output_contains '  ? Make the change'
    assert_output_not_contains 'message of the tool'
    assert_matches "$(tail -n 1 <<<"$RUN_OUTPUT")" '^IMPACT_RESULT status=error code=143 path= reason=interrupted$'
}

# A question that --yes does not answer (the command sets IMPACT_ASSUME_YES
# to 0 for it) names its own way out when no terminal is available, and
# never tells the reader to add --yes, which was perhaps given already.
test_confirm_without_terminal_names_the_given_way_out() {
    make_command asks-hard <<'END'
impact_parse_args 'dry-run yes' '' '' "$@"
IMPACT_ASSUME_YES=0
if impact_confirm "Delete everything?" yes "This question is answered on a terminal only."; then
    echo "confirmed"
else
    echo "not confirmed"
    exit 1
fi
END
    run_cmd timeout 20 setsid --wait "$TEST_TMP/asks-hard" --yes
    assert_status 1
    assert_output_contains 'no terminal is available'
    assert_output_contains 'This question is answered on a terminal only.'
    assert_output_not_contains 'add the option --yes'
    assert_output_contains 'not confirmed'
}

# Confirm reads the answer from the terminal.
test_confirm_reads_the_answer_from_the_terminal() {
    if ! command -v script >/dev/null 2>&1; then
        skip "the tool script (package bsdutils) is not installed"
    fi
    make_command asks <<'END'
impact_parse_args 'dry-run yes' '' '' "$@"
if impact_confirm "Remove the account alice?" alice; then
    echo "confirmed"
else
    echo "not confirmed"
fi
END
    # "script" runs a command inside a new terminal and passes its own
    # standard input to that terminal as if it were typed.
    local output
    output="$(printf 'alice\n' | timeout 20 script -q -e -c "$TEST_TMP/asks" /dev/null 2>&1)" || true
    assert_contains "$output" 'Type alice and press Enter'
    assert_contains "$output" 'confirmed'
    assert_not_contains "$output" 'not confirmed'
    output="$(printf 'yes\n' | timeout 20 script -q -e -c "$TEST_TMP/asks" /dev/null 2>&1)" || true
    assert_contains "$output" 'not confirmed'
}

# Log is not written without root or in a dry run.
test_log_is_not_written_without_root_or_in_a_dry_run() {
    make_command logs <<'END'
impact_parse_args 'dry-run' '' '' "$@"
impact_log_enable "$@"
impact_changed "Pretend to change something"
impact_summary
END
    if ((EUID == 0)); then
        if [[ -e /opt/impact/admin/log/impact-admin.log ]]; then
            skip "a log exists on this machine; the log is tested in the system tests"
        fi
        # As root only the dry run is safe to try here: it must not create
        # the log.
        run_cmd "$TEST_TMP/logs" --dry-run
        assert_status 0
        assert_missing /opt/impact/admin/log/impact-admin.log
    else
        run_cmd "$TEST_TMP/logs"
        assert_status 0
        assert_output_not_contains 'log'
    fi
}

# impact_invoking_account takes SUDO_USER only when it names a real account.
test_invoking_account() {
    load_library
    assert_eq "$(id -un)" "$(SUDO_USER='' impact_invoking_account)"
    # A SUDO_USER that names no account is ignored.
    assert_eq "$(id -un)" "$(SUDO_USER='no-such-account-xyz' impact_invoking_account)"
    assert_eq "$(id -un)" "$(SUDO_USER='$(id)' impact_invoking_account)"
    assert_eq 'root' "$(SUDO_USER='root' impact_invoking_account)"
}

# Dir and file facts.
test_dir_and_file_facts() {
    load_library
    local me group
    me="$(id -un)"
    group="$(id -gn)"
    mkdir -m 750 "$TEST_TMP/folder"
    assert_success impact_dir_is "$TEST_TMP/folder" 750 "$me" "$group"
    assert_fails impact_dir_is "$TEST_TMP/folder" 755 "$me" "$group"
    assert_fails impact_dir_is "$TEST_TMP/missing" 750 "$me" "$group"
    ln -s "$TEST_TMP/folder" "$TEST_TMP/link"
    assert_fails impact_dir_is "$TEST_TMP/link" 750 "$me" "$group"
    assert_success impact_make_dir "$TEST_TMP/new/deep" 700 "$me" "$group"
    assert_success impact_dir_is "$TEST_TMP/new/deep" 700 "$me" "$group"
    assert_success impact_make_dir "$TEST_TMP/new/deep" 750 "$me" "$group"
    assert_success impact_dir_is "$TEST_TMP/new/deep" 750 "$me" "$group"
    run_cmd impact_make_dir "$TEST_TMP/link" 750 "$me" "$group"
    assert_status 1
    assert_output_contains 'symbolic link'
    : >"$TEST_TMP/plain"
    chmod 640 "$TEST_TMP/plain"
    assert_success impact_file_is "$TEST_TMP/plain" 640 "$me" "$group"
    assert_fails impact_file_is "$TEST_TMP/plain" 644 "$me" "$group"
    run_cmd impact_make_dir "$TEST_TMP/plain" 750 "$me" "$group"
    assert_status 1
    printf 'same\n' >"$TEST_TMP/a"
    printf 'same\n' >"$TEST_TMP/b"
    printf 'other\n' >"$TEST_TMP/c"
    assert_success impact_file_has_content "$TEST_TMP/a" "$TEST_TMP/b"
    assert_fails impact_file_has_content "$TEST_TMP/a" "$TEST_TMP/c"
    assert_fails impact_file_has_content "$TEST_TMP/missing" "$TEST_TMP/a"
}

# Changed and undo without impact do.
test_changed_and_undo_without_impact_do() {
    make_command records <<'END'
impact_parse_args 'dry-run' '' '' "$@"
impact_changed "Remove three stopped containers"
impact_undo "Start them again by hand"
impact_summary
END
    run_cmd "$TEST_TMP/records"
    assert_status 0
    assert_output_contains 'What changed:'
    assert_output_contains '  + Remove three stopped containers'
    assert_output_contains '  - Start them again by hand'
}

# Require conf stops with exit code 3 on an unprepared machine.
test_require_conf_stops_with_exit_code_3_on_an_unprepared_machine() {
    if [[ -e /etc/impact/impact.conf ]]; then
        skip "this machine has a settings file"
    fi
    make_command needs-settings <<'END'
impact_result_enable
impact_parse_args '' '' '' "$@"
impact_require_conf
echo "not reached"
END
    run_cmd "$TEST_TMP/needs-settings"
    assert_status 3
    assert_output_contains 'The settings file /etc/impact/impact.conf does not exist.'
    assert_output_contains 'is not prepared'
    assert_output_not_contains 'not reached'
    assert_eq 'IMPACT_RESULT status=error code=3 path= reason=not_prepared' "$(printf '%s\n' "$RUN_OUTPUT" | tail -n 1)"
    # The read-only variant reports and returns, for commands that must run
    # on an unprepared machine.
    load_library
    assert_fails impact_conf_load
    assert_contains "${IMPACT_CONF_ERRORS[*]}" 'does not exist'
}
