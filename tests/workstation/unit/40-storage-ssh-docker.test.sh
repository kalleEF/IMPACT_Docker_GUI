#!/bin/bash
# =============================================================================
# 40-storage-ssh-docker.test.sh: unit tests for the pure parts of
# impact-storage.sh, impact-ssh.sh and impact-docker.sh
#
# Purpose
#   Proves: path containment, the lists of system and home folders, the
#   refusals of the storage safety check, the PermitOpen line and the rules
#   file, the check of the Include line in sshd_config, and the list of
#   read-only docker commands.
#   The parts that need root (applying rules to folders, the SSH procedure)
#   are tested in ../system.
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (no special rights needed)
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter 40-storage
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

setup() {
    load_library
}

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------

# impact_path_is_below: a folder is not below itself, and a name with the same
# beginning (shared2) is another folder.
test_path_is_below() {
    assert_success impact_path_is_below /mnt/disk_a/shared/Model /mnt/disk_a/shared
    assert_success impact_path_is_below /mnt/disk_a/shared/Model/outputs/x /mnt/disk_a/shared
    assert_success impact_path_is_below /a /
    assert_success impact_path_is_below /mnt/disk_a/shared/Model /mnt/disk_a/shared/
    # The folder itself is not "below" itself.
    assert_fails impact_path_is_below /mnt/disk_a/shared /mnt/disk_a/shared
    assert_fails impact_path_is_below / /
    # A name that only starts with the same letters is another folder.
    assert_fails impact_path_is_below /mnt/disk_a/shared2/Model /mnt/disk_a/shared
    assert_fails impact_path_is_below /mnt/disk_a/sharedModel /mnt/disk_a/shared
    assert_fails impact_path_is_below /mnt/disk_b/shared/Model /mnt/disk_a/shared
    assert_fails impact_path_is_below /mnt/disk_a /mnt/disk_a/shared
}

# Path is below refuses unclean paths.
test_path_is_below_refuses_unclean_paths() {
    # ".." would climb out of the parent; such a text is never "below".
    assert_fails impact_path_is_below /mnt/disk_a/shared/../../etc /mnt/disk_a/shared
    assert_fails impact_path_is_below /mnt/disk_a/shared/x/.. /mnt/disk_a/shared
    assert_fails impact_path_is_below /mnt/disk_a/shared/./x /mnt/disk_a/shared
    assert_fails impact_path_is_below /mnt/disk_a/shared//x /mnt/disk_a/shared
    assert_fails impact_path_is_below shared/x shared
    assert_fails impact_path_is_below /mnt/disk_a/shared/x mnt/disk_a/shared
    assert_fails impact_path_is_below '' /mnt
    assert_fails impact_path_is_below /mnt/x ''
    assert_fails impact_path_is_below /mnt/x/y /mnt/x/../x
}

# impact_nearest_existing prints the path itself or its closest existing
# parent.
test_nearest_existing() {
    mkdir -p "$TEST_TMP/a/b"
    assert_eq "$TEST_TMP/a/b" "$(impact_nearest_existing "$TEST_TMP/a/b")"
    assert_eq "$TEST_TMP/a/b" "$(impact_nearest_existing "$TEST_TMP/a/b/c/d/e")"
    assert_eq '/' "$(impact_nearest_existing /no-such-top-folder-xyz/a)"
}

# Only ext4, xfs and btrfs count as file systems for the shared storage.
test_fs_type_supported() {
    local type
    for type in ext4 xfs btrfs; do
        assert_success impact_fs_type_supported "$type"
    done
    for type in ext3 ext2 overlay tmpfs nfs nfs4 cifs vfat ntfs fuseblk zfs ''; do
        assert_fails impact_fs_type_supported "$type"
    done
}

# Fs type of an existing and a missing path.
test_fs_type_of_an_existing_and_a_missing_path() {
    if ! command -v findmnt >/dev/null 2>&1; then
        skip "the tool findmnt is not installed"
    fi
    local type
    type="$(impact_fs_type /)"
    assert_ne '' "$type" "file system type of /"
    assert_eq "$(impact_fs_type "$TEST_TMP")" "$(impact_fs_type "$TEST_TMP/not/yet/there")" \
        "a missing path counts as its closest existing parent"
}

# impact_is_system_path names the system folders and the top folders, and
# accepts folders on storage disks.
test_system_paths() {
    local path
    for path in / /etc /etc/ssh /usr /usr/local/bin /var /var/lib/docker /home /mnt /srv /opt /opt/impact \
        /opt/impact/admin /tmp /tmp/x /root /root/x /proc/1 /sys /dev /run /boot /bin /lib /snap/x; do
        assert_success impact_is_system_path "$path"
    done
    for path in /mnt/disk_a /mnt/disk_a/shared /mnt/disk_a/shared/Model /srv/data /srv/data/x /data/shared \
        /media/disk/shared /opt/other /opt/impactx; do
        assert_fails impact_is_system_path "$path"
    done
}

# Model dir counts as system path once settings are loaded.
test_model_dir_counts_as_system_path_once_settings_are_loaded() {
    assert_fails impact_is_system_path /srv/impact/models/Example
    IMPACT_CONF[MODEL_DIR]=/srv/impact/models
    assert_success impact_is_system_path /srv/impact/models
    assert_success impact_is_system_path /srv/impact/models/Example
    assert_fails impact_is_system_path /srv/impact/other
}

# impact_is_home_path names /home and everything in it, and no folder that
# only has a similar name.
test_home_paths() {
    assert_success impact_is_home_path /home
    assert_success impact_is_home_path /home/alice
    assert_success impact_is_home_path /home/alice/Repositories/Model/outputs
    assert_fails impact_is_home_path /mnt/disk_a/shared
    assert_fails impact_is_home_path /homes/x
    assert_fails impact_is_home_path /srv/home
}

# Storage check target refusals.
test_storage_check_target_refusals() {
    IMPACT_CONF[SHARED_ROOTS]=/mnt/disk_a/shared
    IMPACT_CONF[MODEL_DIR]=/srv/impact/models
    assert_fails impact_storage_check_target 'relative/path'
    assert_contains "$IMPACT_STORAGE_ERROR" 'no absolute path'
    assert_fails impact_storage_check_target ''
    assert_fails impact_storage_check_target /no-such-folder-xyz/a
    assert_contains "$IMPACT_STORAGE_ERROR" 'does not exist'
    assert_fails impact_storage_check_target /etc/hostname
    assert_fails impact_storage_check_target /etc
    assert_contains "$IMPACT_STORAGE_ERROR" 'system folder'
    assert_fails impact_storage_check_target /
    assert_fails impact_storage_check_target /usr/share
    assert_contains "$IMPACT_STORAGE_ERROR" 'system folder'
    # A symbolic link that points into a system folder is resolved first.
    ln -s /etc "$TEST_TMP/link-to-etc"
    assert_fails impact_storage_check_target "$TEST_TMP/link-to-etc"
    assert_contains "$IMPACT_STORAGE_ERROR" 'system folder'
    assert_eq '' "$IMPACT_STORAGE_PATH"
    # An existing folder outside every storage root.
    mkdir -p "$TEST_TMP/outside"
    assert_fails impact_storage_check_target "$TEST_TMP/outside"
    assert_eq '' "$IMPACT_STORAGE_PATH"
    assert_eq '' "$IMPACT_STORAGE_ROOT"
}

# Shared functions refuse folders outside the roots.
test_shared_functions_refuse_folders_outside_the_roots() {
    IMPACT_CONF[SHARED_ROOTS]=/mnt/disk_a/shared
    mkdir -p "$TEST_TMP/folder"
    : >"$TEST_TMP/folder/file"
    # The group "root" exists on every machine; the refusal must come from
    # the place of the folder.
    assert_fails impact_shared_dir_is_ok "$TEST_TMP/folder" root
    assert_contains "$IMPACT_STORAGE_ERROR" 'inside none of the storage roots'
    run_cmd impact_shared_apply_dir "$TEST_TMP/folder" root
    assert_status 1
    assert_output_contains 'inside none of the storage roots'
    run_cmd impact_shared_apply_dir /etc root
    assert_status 1
    run_cmd impact_shared_apply_files root -- "$TEST_TMP/folder/file"
    assert_status 1
    assert_output_contains 'no plain file inside a storage root'
    assert_fails impact_shared_file_is_ok "$TEST_TMP/folder/file" root
    # A group that does not exist is refused as well.
    run_cmd impact_shared_apply_dir "$TEST_TMP/folder" no-such-group-xyz
    assert_status 1
    assert_output_contains 'does not exist'
}

# ----------------------------------------------------------------------------
# SSH rules
# ----------------------------------------------------------------------------

# impact_permitopen_line writes one 127.0.0.1:<port> entry per port of the
# range, and refuses a wrong range.
test_permitopen_line() {
    assert_eq 'PermitOpen 127.0.0.1:8787' "$(impact_permitopen_line 8787 8787)"
    assert_eq 'PermitOpen 127.0.0.1:8787 127.0.0.1:8788 127.0.0.1:8789' "$(impact_permitopen_line 8787 8789)"
    local line
    line="$(impact_permitopen_line 8787 8830)"
    # Count the entries: split the line at blanks into a list.
    local -a words=()
    read -r -a words <<<"$line"
    assert_eq 45 "${#words[@]}" "the word PermitOpen plus 44 entries"
    assert_eq '127.0.0.1:8830' "${words[44]}"
    assert_not_contains "$line" 'localhost'
    line="$(impact_permitopen_line 8000 8199)"
    read -r -a words <<<"$line"
    assert_eq 201 "${#words[@]}" "200 ports are the upper limit"
}

# Permitopen line refuses bad ranges.
test_permitopen_line_refuses_bad_ranges() {
    assert_fails impact_permitopen_line 8789 8787
    assert_fails impact_permitopen_line 8000 8200
    assert_fails impact_permitopen_line 80 90
    assert_fails impact_permitopen_line 8787 70000
    assert_fails impact_permitopen_line '' 8787
    assert_fails impact_permitopen_line 8787 ''
    assert_fails impact_permitopen_line '8787; id' 8790
    assert_fails impact_permitopen_line 8787 '8790 0.0.0.0:22'
}

# Rules content is the agreed block.
test_rules_content_is_the_agreed_block() {
    local content
    content="$(impact_ssh_rules_content impact 8787 8789)"
    # Remove comment lines; the rest must be exactly the agreed block.
    local expected
    expected="$(
        cat <<'END'
Match Group impact
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding local
    PermitOpen 127.0.0.1:8787 127.0.0.1:8788 127.0.0.1:8789
    AllowStreamLocalForwarding no
    GatewayPorts no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
    ClientAliveInterval 60
    ClientAliveCountMax 3
END
    )"
    assert_eq "$expected" "$(printf '%s\n' "$content" | grep -v '^#')"
    # Every line before the Match line is a comment.
    assert_eq '' "$(printf '%s\n' "$content" | sed -e '/^Match /,$d' | grep -v '^#' || true)"
    content="$(impact_ssh_rules_content research-team 9000 9001)"
    assert_contains "$content" 'Match Group research-team'
    assert_contains "$content" 'PermitOpen 127.0.0.1:9000 127.0.0.1:9001'
}

# Rules content refuses bad input.
test_rules_content_refuses_bad_input() {
    assert_fails impact_ssh_rules_content 'impact evil' 8787 8789
    assert_fails impact_ssh_rules_content $'impact\nPermitRootLogin yes' 8787 8789
    assert_fails impact_ssh_rules_content 'impact,wheel' 8787 8789
    assert_fails impact_ssh_rules_content '*' 8787 8789
    assert_fails impact_ssh_rules_content impact 8789 8787
    assert_fails impact_ssh_rules_content '' 8787 8789
}

# impact_ssh_expected_member_values prints the twelve values that a member
# must get, and refuses a wrong range.
test_expected_member_values() {
    local values
    values="$(impact_ssh_expected_member_values 8787 8788)"
    assert_eq 12 "$(printf '%s\n' "$values" | wc -l)"
    assert_contains "$values" 'permitopen 127.0.0.1:8787 127.0.0.1:8788'
    assert_contains "$values" 'authenticationmethods publickey'
    assert_contains "$values" 'passwordauthentication no'
    assert_contains "$values" 'allowtcpforwarding local'
    assert_contains "$values" 'clientalivecountmax 3'
    assert_fails impact_ssh_expected_member_values 9 8
}

# The Include line of sshd_config is found in its usual forms, and only before
# the first Match line.
test_include_line_check() {
    local config="$TEST_TMP/sshd_config"
    # The form of Ubuntu's default file.
    printf '# comment\n\nInclude /etc/ssh/sshd_config.d/*.conf\n\nKbdInteractiveAuthentication no\n' >"$config"
    assert_success impact_ssh_config_includes_rules "$config"
    # Other accepted forms.
    printf 'include   /etc/ssh/sshd_config.d/*.conf\n' >"$config"
    assert_success impact_ssh_config_includes_rules "$config"
    printf 'Include "/etc/ssh/sshd_config.d/*.conf"\n' >"$config"
    assert_success impact_ssh_config_includes_rules "$config"
    printf 'Include sshd_config.d/*.conf\n' >"$config"
    assert_success impact_ssh_config_includes_rules "$config"
    printf 'Include=/etc/ssh/sshd_config.d/*\n' >"$config"
    assert_success impact_ssh_config_includes_rules "$config"
    printf 'Include /etc/ssh/other.conf /etc/ssh/sshd_config.d/60-*.conf\n' >"$config"
    assert_success impact_ssh_config_includes_rules "$config"
}

# Include line check refusals.
test_include_line_check_refusals() {
    local config="$TEST_TMP/sshd_config"
    printf 'PasswordAuthentication yes\n' >"$config"
    assert_fails impact_ssh_config_includes_rules "$config"
    printf '#Include /etc/ssh/sshd_config.d/*.conf\n' >"$config"
    assert_fails impact_ssh_config_includes_rules "$config"
    printf 'Include /etc/ssh/other.d/*.conf\n' >"$config"
    assert_fails impact_ssh_config_includes_rules "$config"
    printf 'Include /etc/ssh/sshd_config.d/50-*.conf\n' >"$config"
    assert_fails impact_ssh_config_includes_rules "$config"
    # An Include after a Match line applies to some logins only.
    printf 'Match User someone\n    Include /etc/ssh/sshd_config.d/*.conf\n' >"$config"
    assert_fails impact_ssh_config_includes_rules "$config"
    assert_fails impact_ssh_config_includes_rules "$TEST_TMP/missing"
}

# impact_ssh_client_address takes the address of the administrator's session
# from SSH_CONNECTION, and 127.0.0.1 for anything that is no address.
test_client_address() {
    local address
    address="$(SSH_CONNECTION='192.0.2.7 51234 192.0.2.1 22' impact_ssh_client_address)"
    assert_eq '192.0.2.7' "$address"
    address="$(SSH_CONNECTION='2001:db8::7 51234 2001:db8::1 22' impact_ssh_client_address)"
    assert_eq '2001:db8::7' "$address"
    # A value that is no address is never passed on to sshd.
    address="$(SSH_CONNECTION='$(id),user=root 1 2 3' impact_ssh_client_address)"
    assert_eq '127.0.0.1' "$address"
    address="$(SSH_CONNECTION='host.example.org 1 2 3' impact_ssh_client_address)"
    assert_eq '127.0.0.1' "$address"
}

# Effective settings refuse unusable names.
test_effective_settings_refuse_unusable_names() {
    # A comma in the name would add a second condition for sshd.
    assert_fails impact_ssh_effective 'alice,addr=192.0.2.1'
    assert_fails impact_ssh_effective 'alice' 'not an address'
    assert_fails impact_ssh_effective '' 127.0.0.1
    assert_fails impact_ssh_effective 'alice' '127.0.0.1,user=root'
}

# ----------------------------------------------------------------------------
# Docker
# ----------------------------------------------------------------------------


# fake_sshd_T [PORT...]
#   Replaces the library function impact__sshd_T by a stand-in that behaves
#   like sshd 8.9 of Ubuntu 22.04: it prints the "port" lines and the
#   "pidfile" line first, then about 100 KB of further settings, one write
#   per line. A reader that closes the pipe early makes it end with the
#   signal SIGPIPE (exit status 141), as the real sshd 8.9 does.
#   The pid file named is $TEST_TMP/sshd.pid.
fake_sshd_T() {
    local port
    {
        printf '#!/bin/bash\n'
        for port in "$@"; do
            printf 'printf "port %s\\n"\n' "$port"
        done
        printf 'printf "listenaddress 0.0.0.0:%s\\n"\n' "${1:-22}"
        printf 'printf "pidfile %s\\n"\n' "$TEST_TMP/sshd.pid"
        printf 'for ((i = 0; i < 2000; i++)); do printf "setting%%05d %%s\\n" "$i" "................................................"; done\n'
    } >"$TEST_TMP/fake-sshd-T"
    chmod 755 "$TEST_TMP/fake-sshd-T"
    # A function of the same name, defined after the library was loaded,
    # replaces the library's own function for this test process.
    # shellcheck disable=SC2317
    # Reason for SC2317 (command appears unreachable): the library calls it.
    impact__sshd_T() {
        "$TEST_TMP/fake-sshd-T"
    }
}

# The values of sshd -T are found although sshd prints much more after
# them, also with "set -o pipefail" (each test runs with it): a reader that
# stopped early would lose the whole answer on Ubuntu 22.04.
test_sshd_values_are_read_from_the_whole_output() {
    fake_sshd_T 2222 2200
    # The stand-in really dies of SIGPIPE when its reader stops early.
    local status=0
    "$TEST_TMP/fake-sshd-T" | head -n 1 >/dev/null || status=$?
    assert_eq 141 "$status" "exit status of the stand-in when the reader stops early"
    # The question succeeds (status 0) and gives the value.
    assert_success impact__sshd_config_values pidfile
    assert_eq "$TEST_TMP/sshd.pid" "$(impact__sshd_config_values pidfile)" "pidfile"
    assert_eq $'2222\n2200' "$(impact__sshd_config_values port)" "both port lines"
    assert_eq '' "$(impact__sshd_config_values nosuchsetting)" "a setting sshd does not print"
}

# impact_ssh_listening tries every port that sshd -T names (here 2222 and
# 2200), and port 22 last, on the loopback addresses.
test_probe_targets_follow_the_ports_of_sshd() {
    fake_sshd_T 2222 2200
    local targets
    targets="$(impact__ssh_probe_targets)"
    assert_contains "$targets" '127.0.0.1 2222'
    assert_contains "$targets" '127.0.0.1 2200'
    assert_contains "$targets" '::1 2222'
    # Port 22 stays the last fallback, and no pair appears twice.
    assert_eq '127.0.0.1 2222' "$(printf '%s\n' "$targets" | head -n 1)" "first target (from listenaddress 0.0.0.0:2222)"
    assert_eq "$(printf '%s\n' "$targets" | sort -u | wc -l)" "$(printf '%s\n' "$targets" | wc -l)" "each pair once"
}

# Without systemd, impact_ssh_reload sends the signal HUP to the process
# named in sshd's PidFile, when its program name is sshd. The stand-in
# server here is a copy of "sleep" named sshd; HUP ends it.
test_reload_without_systemd_finds_the_server_through_the_pid_file() {
    if [[ -d /run/systemd/system ]]; then
        skip "systemd runs on this machine; the branch without systemd is tested where it does not run"
    fi
    fake_sshd_T 22
    cp "$(command -v sleep)" "$TEST_TMP/sshd"
    "$TEST_TMP/sshd" 300 &
    local pid=$!
    printf '%s\n' "$pid" >"$TEST_TMP/sshd.pid"
    assert_success impact_ssh_reload
    assert_eq 'reloaded' "$IMPACT_SSH_RELOAD_STATE" "reload state"
    # The signal ended the stand-in: wait returns 128 + 1 (HUP).
    local status=0
    wait "$pid" || status=$?
    assert_eq 129 "$status" "exit status of the stand-in after HUP"
    # A pid file that names another program is never signalled.
    sleep 300 &
    pid=$!
    printf '%s\n' "$pid" >"$TEST_TMP/sshd.pid"
    assert_success impact_ssh_reload
    assert_eq 'none' "$IMPACT_SSH_RELOAD_STATE" "reload state for a process that is no sshd"
    kill "$pid"
}

# fake_tools
#   Puts stand-ins for "docker" and "dockerd" in front of the PATH of this
#   test. The stand-ins print fixed answers and write their arguments to a
#   file, so a test can see what would have been asked.
fake_tools() {
    mkdir -p "$TEST_TMP/bin"
    cat >"$TEST_TMP/bin/dockerd" <<'END'
#!/bin/bash
echo "Docker version 29.1.0, build 1234abc"
END
    cat >"$TEST_TMP/bin/docker" <<END
#!/bin/bash
printf '%s\n' "\$*" >>"$TEST_TMP/docker-calls"
if [ "\$1" = version ]; then echo "\${FAKE_SERVER_VERSION:-29.1.0}"; exit "\${FAKE_DOCKER_STATUS:-0}"; fi
echo "docker stand-in: \$*"
END
    chmod 755 "$TEST_TMP/bin/dockerd" "$TEST_TMP/bin/docker"
    PATH="$TEST_TMP/bin:$PATH"
}

# Docker ro refuses changing commands.
test_docker_ro_refuses_changing_commands() {
    fake_tools
    local subcommand
    for subcommand in run rm rmi stop start kill exec build pull push create restart rename update cp commit \
        tag load import login prune 'system prune' 'image rm' 'image prune' 'container rm' 'container stop' \
        'volume rm' 'volume create' 'volume prune' 'network create' 'network rm' 'builder prune' ''; do
        # shellcheck disable=SC2086
        # Reason for SC2086 (unquoted variable): a two-word entry must become
        # two arguments here.
        run_cmd impact_docker_ro $subcommand
        assert_status 2
    done
    assert_missing "$TEST_TMP/docker-calls"
}

# Docker ro passes reading commands on.
test_docker_ro_passes_reading_commands_on() {
    fake_tools
    run_cmd impact_docker_ro ps --all --filter 'label=impact.account=alice' --format '{{.Names}}'
    assert_status 0
    assert_output_contains 'docker stand-in: ps --all --filter label=impact.account=alice --format {{.Names}}'
    local subcommand
    for subcommand in images inspect info port top logs diff history 'image ls' 'image inspect' \
        'container ls' 'container inspect' 'volume ls' 'volume inspect' 'network ls' 'system df'; do
        # shellcheck disable=SC2086
        # Reason for SC2086: a two-word entry must become two arguments here.
        run_cmd impact_docker_ro $subcommand
        assert_status 0
    done
}

# Docker versions with stand ins.
test_docker_versions_with_stand_ins() {
    fake_tools
    assert_eq '29.1.0' "$(impact_docker_engine_version)"
    assert_eq '29.1.0' "$(impact_docker_server_version)"
    assert_success impact_docker_daemon_reachable
    assert_eq '28.3.3' "$IMPACT_DOCKER_MIN_VERSION"
    assert_success impact_version_ge "$(impact_docker_engine_version)" "$IMPACT_DOCKER_MIN_VERSION"
    # A daemon that does not answer.
    FAKE_DOCKER_STATUS=1 FAKE_SERVER_VERSION='' run_cmd impact_docker_daemon_reachable
    assert_status 1
    export FAKE_SERVER_VERSION='Cannot connect to the Docker daemon'
    assert_fails impact_docker_server_version
}

# Docker missing is reported.
test_docker_missing_is_reported() {
    # An empty folder as the only PATH entry: no docker anywhere.
    mkdir -p "$TEST_TMP/empty"
    # shellcheck disable=SC2123
    # Reason for SC2123 (PATH is the search path): changing the search path
    # is the purpose of this test.
    PATH="$TEST_TMP/empty"
    assert_fails impact_docker_installed
    assert_fails impact_docker_engine_version
    assert_fails impact_docker_server_version
    assert_fails impact_docker_daemon_reachable
}

# ----------------------------------------------------------------------------
# Downloads
# ----------------------------------------------------------------------------

# fake_curl STATUS_CODE EXIT_CODE
#   Puts a stand-in for "curl" in front of the PATH of this test. It writes
#   its arguments to a file, writes a fixed text to the file named after
#   --output, prints STATUS_CODE and ends with EXIT_CODE.
fake_curl() {
    mkdir -p "$TEST_TMP/bin"
    cat >"$TEST_TMP/bin/curl" <<END
#!/bin/bash
printf '%s\n' "\$*" >>"$TEST_TMP/curl-calls"
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = --output ]; then printf 'downloaded text\n' >"\$2"; fi
    shift
done
printf '%s' "$1"
exit $2
END
    chmod 755 "$TEST_TMP/bin/curl"
    PATH="$TEST_TMP/bin:$PATH"
}

# Https get refuses other addresses without calling curl.
test_https_get_refuses_other_addresses_without_calling_curl() {
    fake_curl 200 0
    local url
    for url in 'http://github.com/alice-example.keys' 'file:///etc/passwd' 'ftp://example.org/x' \
        'https://github.com/alice-example.keys?x=1' 'https://github.com/a b' 'https://user@example.org/x' \
        'https://example.org/x;id' 'https://example.org/$(id)' 'https://' '' '-o /etc/passwd https://example.org' \
        'https://example.org:8443/x' 'https://example.org/x#y'; do
        run_cmd impact_https_get "$url" "$TEST_TMP/out"
        assert_status 2
    done
    assert_missing "$TEST_TMP/curl-calls"
    assert_missing "$TEST_TMP/out"
}

# Https get result codes.
test_https_get_result_codes() {
    fake_curl 200 0
    assert_success impact_https_get 'https://github.com/alice-example.keys' "$TEST_TMP/out"
    assert_eq '200' "$IMPACT_HTTP_STATUS"
    assert_eq 'downloaded text' "$(cat "$TEST_TMP/out")"
    assert_file_contains "$TEST_TMP/curl-calls" '--proto =https'
    assert_file_contains "$TEST_TMP/curl-calls" '--proto-redir =https'
    assert_file_contains "$TEST_TMP/curl-calls" '--max-time 30'
    assert_file_contains "$TEST_TMP/curl-calls" '-- https://github.com/alice-example.keys'
    local status
    # The address does not exist: curl ends with 22 and prints 404.
    fake_curl 404 22
    status=0
    impact_https_get 'https://github.com/no-such-name.keys' "$TEST_TMP/out" || status=$?
    assert_eq 5 "$status" "exit code for an answer 404"
    assert_eq '404' "$IMPACT_HTTP_STATUS"
    # No connection: curl ends with 6 or 7 and prints 000.
    fake_curl 000 7
    status=0
    impact_https_get 'https://github.com/alice-example.keys' "$TEST_TMP/out" || status=$?
    assert_eq 6 "$status" "exit code for a network problem"
    assert_eq '000' "$IMPACT_HTTP_STATUS"
    # A server error counts as a network problem.
    fake_curl 503 22
    status=0
    impact_https_get 'https://github.com/alice-example.keys' "$TEST_TMP/out" || status=$?
    assert_eq 6 "$status"
}

# An answer larger than 1 MB is refused also when curl let it through: curl
# before version 8.4 (Ubuntu 22.04) applies --max-filesize only to answers
# that announce their size. The stand-in writes 2 MB and reports success.
test_https_get_refuses_an_answer_over_one_megabyte() {
    fake_curl 200 0
    sed -i -e 's|printf .downloaded text\\n. >"\$2"|head -c 2097152 /dev/zero >"$2"|' "$TEST_TMP/bin/curl"
    local status=0
    impact_https_get 'https://github.com/alice-example.keys' "$TEST_TMP/out" 2>"$TEST_TMP/err" || status=$?
    assert_eq 6 "$status" "exit code for an answer over 1 MB"
    assert_eq 0 "$(stat -c '%s' -- "$TEST_TMP/out")" "size of the output file afterwards"
    assert_file_contains "$TEST_TMP/err" 'is larger than 1 MB'
}

# Docker source and boot state give one of the agreed words.
test_docker_source_and_boot_state_give_one_of_the_agreed_words() {
    local word
    word="$(impact_docker_install_source)"
    assert_matches "$word" '^(docker-ce|snap|docker\.io|other|none)$' "install source"
    word="$(impact_docker_boot_state)"
    assert_matches "$word" '^(enabled|socket|disabled|unknown)$' "boot state"
    if [[ ! -d /run/systemd/system ]]; then
        assert_eq 'unknown' "$word" "without systemd the question has no answer"
    fi
    # Without any docker program the source is "none" (or "snap" when the
    # snap package is present outside the search path).
    mkdir -p "$TEST_TMP/empty"
    # shellcheck disable=SC2123
    # Reason for SC2123 (PATH is the search path): changing the search path
    # is the purpose of this test.
    PATH="$TEST_TMP/empty"
    word="$(impact_docker_install_source)"
    if [[ -e /snap/bin/docker ]]; then
        assert_eq 'snap' "$word"
    else
        assert_eq 'none' "$word"
    fi
}
