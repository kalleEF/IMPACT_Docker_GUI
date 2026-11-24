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

test_nearest_existing() {
    mkdir -p "$TEST_TMP/a/b"
    assert_eq "$TEST_TMP/a/b" "$(impact_nearest_existing "$TEST_TMP/a/b")"
    assert_eq "$TEST_TMP/a/b" "$(impact_nearest_existing "$TEST_TMP/a/b/c/d/e")"
    assert_eq '/' "$(impact_nearest_existing /no-such-top-folder-xyz/a)"
}

test_fs_type_supported() {
    local type
    for type in ext4 xfs btrfs; do
        assert_success impact_fs_type_supported "$type"
    done
    for type in ext3 ext2 overlay tmpfs nfs nfs4 cifs vfat ntfs fuseblk zfs ''; do
        assert_fails impact_fs_type_supported "$type"
    done
}

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

test_model_dir_counts_as_system_path_once_settings_are_loaded() {
    assert_fails impact_is_system_path /srv/impact/models/Example
    IMPACT_CONF[MODEL_DIR]=/srv/impact/models
    assert_success impact_is_system_path /srv/impact/models
    assert_success impact_is_system_path /srv/impact/models/Example
    assert_fails impact_is_system_path /srv/impact/other
}

test_home_paths() {
    assert_success impact_is_home_path /home
    assert_success impact_is_home_path /home/alice
    assert_success impact_is_home_path /home/alice/Repositories/Model/outputs
    assert_fails impact_is_home_path /mnt/disk_a/shared
    assert_fails impact_is_home_path /homes/x
    assert_fails impact_is_home_path /srv/home
}

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

test_rules_content_is_the_block_of_the_specification() {
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

test_rules_content_refuses_bad_input() {
    assert_fails impact_ssh_rules_content 'impact evil' 8787 8789
    assert_fails impact_ssh_rules_content $'impact\nPermitRootLogin yes' 8787 8789
    assert_fails impact_ssh_rules_content 'impact,wheel' 8787 8789
    assert_fails impact_ssh_rules_content '*' 8787 8789
    assert_fails impact_ssh_rules_content impact 8789 8787
    assert_fails impact_ssh_rules_content '' 8787 8789
}

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
