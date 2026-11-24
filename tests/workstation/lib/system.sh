#!/bin/bash
# =============================================================================
# system.sh: helpers for the system tests (root on a disposable system)
#
# Purpose
#   The system tests run the real commands at the real paths. These helpers
#   prepare and clean the disposable system around them: storage roots on a
#   real file system, a stand-in administration account that uses sudo, test
#   accounts with passwords and keys, an SSH server, and logins through it.
#
# Who runs it
#   Nobody directly. testlib.sh loads it. The functions refuse to work
#   unless IMPACT_TEST_DISPOSABLE=yes is set and the process is root.
#
# Usage (inside a system test file)
#   suite_setup() {
#       sys_clean_slate
#       sys_storage_up
#       sys_install
#       sys_admin_create
#       sys_sshd_start
#       sys_setup
#   }
#   suite_teardown() { sys_clean_slate; }
#
# What it changes on the system
#   Accounts, groups, /etc/sudoers.d/impact-test, the folders /mnt/disk_a and
#   /mnt/disk_b, an SSH server process, and everything the commands under
#   test change. sys_clean_slate removes all of it again.
#
# How to undo
#   sys_clean_slate, or throw the disposable system away.
#
# Names used by the tests (neutral examples)
#   SYS_ADMIN      tadmin          stand-in for the administration account
#   SYS_ROOT_A     /mnt/disk_a/shared     first storage root
#   SYS_ROOT_B     /mnt/disk_b/shared     second storage root
#   SYS_GROUP      impact          the shared group
# =============================================================================

# Reading help: the bash constructs used here are explained at the top of
# testlib.sh ("Reading help") and where they are first used.

# Fixed names. "readonly" protects them against a change by mistake.
readonly SYS_ADMIN='tadmin'
readonly SYS_ADMIN_PASSWORD='Admin-Test-Pass-91'
readonly SYS_GROUP='impact'
readonly SYS_ROOT_A='/mnt/disk_a/shared'
readonly SYS_ROOT_B='/mnt/disk_b/shared'
readonly SYS_ADMIN_CONTACT='Alice Example (alice@example.org)'
# Accounts and groups that tests create are noted here, so that
# sys_clean_slate can remove them even after an aborted run.
readonly SYS_REGISTRY_DIR='/var/lib/impact-test'
readonly SYS_SSHD_LOG='/var/log/impact-test-sshd.log'
readonly SYS_SSHD_PID_FILE='/run/sshd.pid'
SYS_SSH_PORT=22

# sys_guard
#   Ends the test unless it runs as root on a system that the caller
#   declared disposable. Every changing helper calls it first.
sys_guard() {
    if [[ "${IMPACT_TEST_DISPOSABLE:-}" != 'yes' || "$EUID" != '0' ]]; then
        fail "system helpers need root and IMPACT_TEST_DISPOSABLE=yes (a disposable system)"
    fi
}

# -----------------------------------------------------------------------------
# Registry of test accounts and groups
# -----------------------------------------------------------------------------

# sys_register_account NAME
#   Notes that the test (or a command under test) creates the account NAME,
#   so sys_clean_slate removes it. Call it BEFORE the account is created.
sys_register_account() {
    sys_guard
    mkdir -p -- "$SYS_REGISTRY_DIR"
    printf '%s\n' "$1" >>"$SYS_REGISTRY_DIR/accounts"
}

# sys_register_group NAME
#   The same for a group.
sys_register_group() {
    sys_guard
    mkdir -p -- "$SYS_REGISTRY_DIR"
    printf '%s\n' "$1" >>"$SYS_REGISTRY_DIR/groups"
}

# -----------------------------------------------------------------------------
# Accounts
# -----------------------------------------------------------------------------

# sys_account_add NAME [GROUP...]
#   Creates a plain test account with a home folder and bash as shell, and
#   adds it to the given groups. The password is locked, as for a colleague.
sys_account_add() {
    sys_guard
    local name="$1" group
    shift
    sys_register_account "$name"
    useradd --create-home --shell /bin/bash -- "$name"
    for group in "$@"; do
        usermod --append --groups "$group" -- "$name"
    done
}

# sys_account_del NAME
#   Ends the processes of a test account and removes it with its home folder.
sys_account_del() {
    sys_guard
    if getent passwd -- "$1" >/dev/null; then
        pkill -KILL -u "$1" 2>/dev/null || true
        userdel --remove --force -- "$1" >/dev/null 2>&1 || true
    fi
}

# sys_set_password NAME PASSWORD
#   Gives a test account a password, to prove that a password login is
#   refused (member) or still possible (other account).
sys_set_password() {
    sys_guard
    # chpasswd reads "name:password" lines.
    printf '%s:%s\n' "$1" "$2" | chpasswd
}

# sys_admin_create
#   Creates the stand-in administration account: a normal account with a
#   password that may use sudo without typing it. It is no member of the
#   shared group, as on the real workstation.
sys_admin_create() {
    sys_guard
    if ! getent passwd -- "$SYS_ADMIN" >/dev/null; then
        sys_account_add "$SYS_ADMIN"
    fi
    sys_set_password "$SYS_ADMIN" "$SYS_ADMIN_PASSWORD"
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$SYS_ADMIN" >/etc/sudoers.d/impact-test
    chmod 440 /etc/sudoers.d/impact-test
}

# sys_as_admin COMMAND [ARGUMENTS...]
#   Runs a command the way the administrator does: logged in as the
#   stand-in account, with "sudo" in front. The command therefore sees
#   SUDO_USER=tadmin, which the log and the SSH safety check use.
#   Example: run_cmd sys_as_admin impact-workstation-setup --dry-run
sys_as_admin() {
    sys_guard
    # runuser switches to the account; "sudo -n" never asks for a password.
    (cd / && runuser -u "$SYS_ADMIN" -- sudo -n -- "$@")
}

# -----------------------------------------------------------------------------
# Storage roots on a real file system
# -----------------------------------------------------------------------------

# sys__fs_ok FOLDER
#   Internal: is FOLDER on a file system the commands accept?
sys__fs_ok() {
    local type
    type="$(findmnt -n -o FSTYPE -T "$1" 2>/dev/null | head -n 1)"
    [[ "$type" == 'ext4' || "$type" == 'xfs' || "$type" == 'btrfs' ]]
}

# sys_storage_up
#   Makes /mnt/disk_a and /mnt/disk_b usable as storage disks: each must lie
#   on ext4, xfs or btrfs. Where /mnt is on another kind of file system (in a
#   container or a copy-on-write view), a folder of IMPACT_TEST_BACKING_DIR
#   is mounted there ("bind mount": the same folder made visible at a second
#   path). The storage roots themselves are created by the command under
#   test or by the test.
#   Skips the test when no real file system is available.
sys_storage_up() {
    sys_guard
    local disk
    for disk in disk_a disk_b; do
        mkdir -p -- "/mnt/$disk"
        if ! sys__fs_ok "/mnt/$disk"; then
            if [[ -z "${IMPACT_TEST_BACKING_DIR:-}" ]]; then
                skip "/mnt is on no ext4, xfs or btrfs file system; set IMPACT_TEST_BACKING_DIR to a folder on one"
            fi
            mkdir -p -- "$IMPACT_TEST_BACKING_DIR/$disk"
            if ! sys__fs_ok "$IMPACT_TEST_BACKING_DIR/$disk"; then
                skip "IMPACT_TEST_BACKING_DIR is on no ext4, xfs or btrfs file system"
            fi
            mount --bind -- "$IMPACT_TEST_BACKING_DIR/$disk" "/mnt/$disk"
        fi
        chown root:root "/mnt/$disk"
        chmod 755 "/mnt/$disk"
    done
}

# sys_storage_down
#   Empties the two test disks and removes the bind mounts.
sys_storage_down() {
    sys_guard
    local disk
    for disk in disk_a disk_b; do
        if [[ -d "/mnt/$disk" ]]; then
            # Remove the content, never the mount point itself.
            find "/mnt/$disk" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
            if mountpoint -q -- "/mnt/$disk"; then
                umount -- "/mnt/$disk" 2>/dev/null || true
            fi
            rmdir -- "/mnt/$disk" 2>/dev/null || true
        fi
        if [[ -n "${IMPACT_TEST_BACKING_DIR:-}" && -d "$IMPACT_TEST_BACKING_DIR/$disk" ]]; then
            rm -rf -- "${IMPACT_TEST_BACKING_DIR:?}/$disk"
        fi
    done
}

# -----------------------------------------------------------------------------
# Clean slate
# -----------------------------------------------------------------------------

# sys_clean_slate
#   Removes everything the commands and the tests can leave behind: SSH
#   server of the tests, SSH rules, settings, installed commands and links,
#   model folders, registered accounts and groups, the shared group, the
#   sudo rule of the stand-in administrator, and the test storage.
#   Call it at the start and at the end of every system test file.
sys_clean_slate() {
    sys_guard
    local name
    sys_sshd_stop
    rm -f -- /etc/ssh/sshd_config.d/60-impact.conf /etc/ssh/sshd_config.d/*impact-test*.conf
    rm -rf -- /etc/impact /opt/impact /srv/impact
    rm -f -- /usr/local/bin/impact-*
    rm -f -- /etc/sudoers.d/impact-test
    sys_fake_systemd_remove
    if [[ -f "$SYS_REGISTRY_DIR/accounts" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] && sys_account_del "$name"
        done <"$SYS_REGISTRY_DIR/accounts"
    fi
    if [[ -f "$SYS_REGISTRY_DIR/groups" ]]; then
        while IFS= read -r name; do
            if [[ -n "$name" ]] && getent group -- "$name" >/dev/null; then
                groupdel -- "$name" 2>/dev/null || true
            fi
        done <"$SYS_REGISTRY_DIR/groups"
    fi
    if getent group -- "$SYS_GROUP" >/dev/null; then
        groupdel -- "$SYS_GROUP" 2>/dev/null || true
    fi
    rm -rf -- "$SYS_REGISTRY_DIR"
    sys_storage_down
}

# -----------------------------------------------------------------------------
# A stand-in for systemd (only for machines where systemd does not run)
# -----------------------------------------------------------------------------

# The first lines of the stand-in program; the marker in line 2 identifies it.
readonly SYS_FAKE_SYSTEMCTL='/usr/local/sbin/systemctl'
readonly SYS_FAKE_MARKER='# impact-test stand-in for systemctl'

# sys_fake_systemd_install ACTIVE_UNIT...
#   For a disposable system WITHOUT systemd: installs a small stand-in
#   program "systemctl" and creates the folder /run/systemd/system, which is
#   the sign by which programs recognise a running systemd. The commands
#   under test then take their "systemd" path. The stand-in answers
#   "is-active" with yes for the given units, turns "reload ssh.service"
#   into the signal HUP for the SSH server of the tests, answers
#   "is-enabled docker.service" with "enabled", and writes every call to
#   /run/impact-test-systemctl.log.
#   It proves that a command calls systemctl in the intended way. It proves
#   nothing about the real systemd.
#   Skips the test when a real systemd runs.
sys_fake_systemd_install() {
    sys_guard
    if [[ -d /run/systemd/system && ! -f /run/systemd/system/.impact-test ]]; then
        skip "a real systemd runs on this machine; the stand-in is for machines without it"
    fi
    mkdir -p /run/systemd/system
    : >/run/systemd/system/.impact-test
    printf '%s\n' "$@" >/run/impact-test-active-units
    : >/run/impact-test-systemctl.log
    # A here-document: the lines up to END become the content of the file.
    # 'END' in quotes keeps every character as written.
    cat >"$SYS_FAKE_SYSTEMCTL" <<'END'
#!/bin/bash
# impact-test stand-in for systemctl
# Used only by the system tests on a machine without systemd.
printf '%s\n' "$*" >>/run/impact-test-systemctl.log
action="${1:-}"
shift || true
case "$action" in
    is-active)
        [ "${1:-}" = --quiet ] && shift
        grep -q -x -F -- "${1:-}" /run/impact-test-active-units
        ;;
    is-enabled)
        if [ "${1:-}" = docker.service ]; then echo enabled; else echo disabled; exit 1; fi
        ;;
    reload)
        if [ -e /run/impact-test-reload-fails ]; then
            echo "Job for ${1:-} failed." >&2
            exit 1
        fi
        kill -HUP "$(cat /run/sshd.pid)"
        ;;
    *)
        exit 0
        ;;
esac
END
    chmod 755 "$SYS_FAKE_SYSTEMCTL"
}

# sys_fake_systemd_remove
#   Removes the stand-in of sys_fake_systemd_install, when present.
sys_fake_systemd_remove() {
    sys_guard
    if [[ -f "$SYS_FAKE_SYSTEMCTL" ]] && grep -q -F -- "$SYS_FAKE_MARKER" "$SYS_FAKE_SYSTEMCTL"; then
        rm -f -- "$SYS_FAKE_SYSTEMCTL"
    fi
    if [[ -f /run/systemd/system/.impact-test ]]; then
        rm -rf -- /run/systemd/system
        rmdir /run/systemd 2>/dev/null || true
    fi
    rm -f -- /run/impact-test-active-units /run/impact-test-systemctl.log /run/impact-test-reload-fails
}

# -----------------------------------------------------------------------------
# Install and set up with the standard test values
# -----------------------------------------------------------------------------

# sys_install
#   Installs the commands from the working copy with install.sh and fails
#   the test when that does not succeed.
sys_install() {
    sys_guard
    run_cmd bash "$WORKSTATION_DIR/install.sh"
    if [[ "$RUN_STATUS" != '0' ]]; then
        show_run
        fail "install.sh failed"
    fi
}

# sys_setup [EXTRA_OPTION...]
#   Runs impact-workstation-setup as the stand-in administrator with the
#   standard test values (both storage roots, the example contact) plus the
#   given options, and fails the test when that does not succeed. Needs
#   sys_storage_up, sys_install and sys_admin_create first.
sys_setup() {
    sys_guard
    run_cmd sys_as_admin /usr/local/bin/impact-workstation-setup \
        --shared-roots "$SYS_ROOT_A,$SYS_ROOT_B" --admin-contact "$SYS_ADMIN_CONTACT" "$@"
    if [[ "$RUN_STATUS" != '0' ]]; then
        show_run
        fail "impact-workstation-setup failed"
    fi
}

# -----------------------------------------------------------------------------
# SSH server
# -----------------------------------------------------------------------------

# sys_ssh_answers
#   Result: success when an SSH server answers on 127.0.0.1, port 22.
sys_ssh_answers() {
    local greeting=''
    # bash opens a network connection through the path /dev/tcp/host/port.
    # The inner bash gets a time limit so that the check cannot hang.
    # shellcheck disable=SC2016
    # Reason for SC2016 (no expansion in single quotes): the inner bash must
    # expand "$line" itself.
    greeting="$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22 && IFS= read -r -t 3 -u 3 line && printf "%s" "$line"' 2>/dev/null)" || greeting=''
    [[ "$greeting" == SSH-* ]]
}

# sys_sshd_start
#   Makes sure an SSH server runs. When one answers already (a machine with
#   its own SSH service), it is used. Otherwise the test starts sshd itself,
#   listening on 127.0.0.1 only, with its process number in /run/sshd.pid.
#   The commands under test reload such a server with the signal HUP, which
#   is their way on a machine without systemd.
sys_sshd_start() {
    sys_guard
    if sys_ssh_answers; then
        return 0
    fi
    # sshd needs this folder; on a normal system the SSH service creates it.
    mkdir -p /run/sshd
    chmod 755 /run/sshd
    : >"$SYS_SSHD_LOG"
    # -o sets one option on the command line; -E writes the server's
    # messages to a file. sshd goes into the background by itself.
    /usr/sbin/sshd -o ListenAddress=127.0.0.1 -o "PidFile=$SYS_SSHD_PID_FILE" -E "$SYS_SSHD_LOG"
    mkdir -p -- "$SYS_REGISTRY_DIR"
    : >"$SYS_REGISTRY_DIR/own-sshd"
    # "_" as the loop variable: the value itself is not needed.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if sys_ssh_answers; then
            return 0
        fi
        sleep 0.5
    done
    cat -- "$SYS_SSHD_LOG" >&2
    fail "the SSH server of the tests did not start"
}

# sys_sshd_stop
#   Stops the SSH server that sys_sshd_start started. A server that was
#   already running before the tests is left alone.
sys_sshd_stop() {
    sys_guard
    local pid=''
    if [[ -f "$SYS_REGISTRY_DIR/own-sshd" && -r "$SYS_SSHD_PID_FILE" ]]; then
        IFS= read -r pid <"$SYS_SSHD_PID_FILE" || pid=''
        if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == 'sshd' ]]; then
            kill "$pid" 2>/dev/null || true
            sleep 0.5
        fi
    fi
    rm -f -- "$SYS_REGISTRY_DIR/own-sshd"
}

# sys_sshd_pid
#   Prints the process number of the SSH server of the tests.
sys_sshd_pid() {
    cat -- "$SYS_SSHD_PID_FILE"
}

# sys_keypair NAME
#   Creates a new ed25519 key pair for a test person in TEST_SUITE_TMP/keys
#   (files NAME and NAME.pub), unless it exists. Prints nothing.
#   The public key is at "$(sys_key_path NAME).pub".
sys_keypair() {
    local folder="$TEST_SUITE_TMP/keys"
    mkdir -p -- "$folder"
    chmod 700 "$folder"
    if [[ ! -f "$folder/$1" ]]; then
        # -t type, -N '' no passphrase, -C comment, -q quiet.
        ssh-keygen -q -t ed25519 -N '' -C "$1@example-pc" -f "$folder/$1"
    fi
}

# sys_key_path NAME
#   Prints the path of the private key made by sys_keypair.
sys_key_path() {
    printf '%s/keys/%s\n' "$TEST_SUITE_TMP" "$1"
}

# sys_install_key ACCOUNT KEY_NAME
#   Puts the public key of sys_keypair into the account's authorized_keys
#   file, for accounts that the test created itself. (Accounts created by
#   impact-add-user get their key from that command.)
sys_install_key() {
    sys_guard
    local account="$1" home
    home="$(getent passwd -- "$account" | cut -d: -f6)"
    install -d -m 700 -o "$account" -g "$account" -- "$home/.ssh"
    install -m 600 -o "$account" -g "$account" -- "$(sys_key_path "$2").pub" "$home/.ssh/authorized_keys"
}

# sys__ssh_options
#   Internal: fills the array SYS_SSH_OPTIONS with client options shared by
#   all test logins: no settings file of the calling account, a separate
#   known_hosts file, a short time limit.
sys__ssh_options() {
    SYS_SSH_OPTIONS=(-F none -o StrictHostKeyChecking=accept-new
        -o "UserKnownHostsFile=$TEST_SUITE_TMP/known_hosts" -o ConnectTimeout=10
        -o LogLevel=ERROR -p "$SYS_SSH_PORT")
}

# sys_ssh_key ACCOUNT KEY_NAME COMMAND [ARGUMENTS...]
#   Logs in to 127.0.0.1 as ACCOUNT with the key of sys_keypair and runs the
#   command there. Only the key is offered; no password is ever asked.
#   Example: run_cmd sys_ssh_key alice alice id -un
sys_ssh_key() {
    local account="$1" key
    key="$(sys_key_path "$2")"
    shift 2
    local -a SYS_SSH_OPTIONS=()
    sys__ssh_options
    timeout 30 ssh "${SYS_SSH_OPTIONS[@]}" -o BatchMode=yes -o IdentitiesOnly=yes \
        -i "$key" "$account@127.0.0.1" "$@" </dev/null
}

# sys_ssh_password ACCOUNT PASSWORD COMMAND [ARGUMENTS...]
#   Tries a password login to 127.0.0.1 as ACCOUNT and runs the command.
#   ssh normally asks for the password on the terminal. Here a small helper
#   program hands it over: SSH_ASKPASS names the program, and
#   SSH_ASKPASS_REQUIRE=force makes ssh use it. "setsid" starts ssh without
#   a terminal.
#   Result: the exit code of ssh (255 when the login is refused).
sys_ssh_password() {
    local account="$1" password="$2" helper="$TEST_SUITE_TMP/askpass"
    shift 2
    if [[ ! -x "$helper" ]]; then
        # shellcheck disable=SC2016
        # Reason for SC2016 (no expansion in single quotes): the helper
        # program must contain the name of the variable, not its value.
        printf '#!/bin/sh\nprintf "%%s\\n" "$IMPACT_TEST_PASSWORD"\n' >"$helper"
        chmod 700 "$helper"
    fi
    local -a SYS_SSH_OPTIONS=()
    sys__ssh_options
    IMPACT_TEST_PASSWORD="$password" SSH_ASKPASS="$helper" SSH_ASKPASS_REQUIRE=force DISPLAY=none \
        timeout 30 setsid ssh "${SYS_SSH_OPTIONS[@]}" \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 "$account@127.0.0.1" "$@" </dev/null
}

# sys_ssh_offered_methods ACCOUNT
#   Prints the login methods the server offers to ACCOUNT, for example
#   "publickey" or "publickey,password". The client offers nothing, so the
#   server answers with its list in the refusal message.
sys_ssh_offered_methods() {
    local account="$1" answer
    local -a SYS_SSH_OPTIONS=()
    sys__ssh_options
    answer="$(timeout 30 ssh "${SYS_SSH_OPTIONS[@]}" -o BatchMode=yes -o PubkeyAuthentication=no \
        "$account@127.0.0.1" true 2>&1 </dev/null)" || true
    # The refusal looks like: Permission denied (publickey,password).
    printf '%s\n' "$answer" | sed -n 's/.*Permission denied (\(.*\))\..*/\1/p' | tail -n 1
}

# sys_effective_ssh ACCOUNT
#   Prints the complete effective SSH settings of ACCOUNT (sshd -T), sorted.
sys_effective_ssh() {
    mkdir -p /run/sshd
    /usr/sbin/sshd -T -C "user=$1,host=127.0.0.1,addr=127.0.0.1" | LC_ALL=C sort
}
