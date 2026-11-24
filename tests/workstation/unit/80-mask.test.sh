#!/bin/bash
# =============================================================================
# 80-mask.test.sh: unit tests for impact_mask_text (impact-common.sh)
#
# Purpose
#   Proves that the filter replaces network addresses, hardware addresses
#   and host names, keeps the addresses that name no particular machine
#   (127.0.0.1, 0.0.0.0, ::1, ::), and leaves ordinary text such as times,
#   versions and port numbers alone.
#
# Who runs it
#   tests/workstation/run-tests.sh unit   (no special rights needed)
#
# Usage
#   bash tests/workstation/run-tests.sh unit --filter 80-mask
#
# What it changes on the system
#   Nothing.
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

# mask TEXT
#   Prints TEXT after it went through the filter.
mask() {
    printf '%s\n' "$1" | impact_mask_text
}

test_ipv4_addresses_are_replaced() {
    assert_eq 'from <address> to <address>' "$(mask 'from 192.0.2.5 to 10.0.0.17')"
    assert_eq '<address>:8787' "$(mask '192.0.2.5:8787')"
    assert_eq '<address>/24' "$(mask '192.0.2.0/24')"
    assert_eq 'addr=<address>,' "$(mask 'addr=192.0.2.5,')"
    assert_eq '(<address>)' "$(mask '(192.0.2.5)')"
    # Two addresses with one character between them.
    assert_eq '<address> <address>' "$(mask '192.0.2.5 192.0.2.6')"
    assert_eq '<address>,<address>' "$(mask '192.0.2.5,192.0.2.6')"
    # An address at the end of a sentence.
    assert_eq 'Login from <address>.' "$(mask 'Login from 192.0.2.5.')"
    assert_eq '<address>' "$(mask '255.255.255.0')"
}

test_loopback_and_all_addresses_are_kept() {
    assert_eq '127.0.0.1:8787->8787/tcp' "$(mask '127.0.0.1:8787->8787/tcp')"
    assert_eq '0.0.0.0:8788->8787/tcp' "$(mask '0.0.0.0:8788->8787/tcp')"
    assert_eq 'PermitOpen 127.0.0.1:8787 127.0.0.1:8788' "$(mask 'PermitOpen 127.0.0.1:8787 127.0.0.1:8788')"
    assert_eq 'listening on 127.0.0.53.' "$(mask 'listening on 127.0.0.53.')"
    assert_eq '[::]:22 and [::1]:8787 and ::1 and :::8787' "$(mask '[::]:22 and [::1]:8787 and ::1 and :::8787')"
    assert_eq '0.0.0.0:22 <address>:22' "$(mask '0.0.0.0:22 192.0.2.9:22')"
}

test_ipv6_addresses_are_replaced() {
    assert_eq 'addr <address> end' "$(mask 'addr 2001:db8::1 end')"
    assert_eq '<address>%eth0' "$(mask 'fe80::a00:27ff:fe4e:66a1%eth0')"
    assert_eq '[<address>]:22' "$(mask '[2001:db8:85a3::8a2e:370:7334]:22')"
    assert_eq '<address>' "$(mask '2001:0db8:85a3:0000:0000:8a2e:0370:7334')"
    assert_eq 'x <address> y' "$(mask 'x fe80:: y')"
    assert_eq 'from <address>.' "$(mask 'from 2001:db8::7.')"
}

test_hardware_addresses_are_replaced() {
    assert_eq 'link/ether <hardware address> brd <hardware address>' \
        "$(mask 'link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff')"
}

test_ordinary_text_is_left_alone() {
    local text
    for text in \
        'Docker Engine 29.10.0 (needed: 28.3.3)' \
        'Ubuntu 24.04.5 LTS, kernel 6.8.0-45-generic' \
        'OpenSSH_9.6p1 Ubuntu-3ubuntu13.5' \
        '2026-01-31T14:05:09Z and 14:05:09' \
        'ports 8787 to 8830, 44 ports' \
        'docker-ce 5:29.1.0-1~ubuntu.22.04~jammy' \
        'sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08' \
        'SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU' \
        'Step 3: Folders   OK: /etc/impact is in order.' \
        'uid=1005(alice) gid=1005(alice) groups=1005(alice),1001(impact),998(docker)' \
        '/mnt/disk_a/shared/Example/outputs 2770 root:impact' \
        '1.2.3 and 1.2.3.4.5'; do
        assert_eq "$text" "$(mask "$text")"
    done
}

test_own_host_name_is_replaced() {
    local name
    name="$(hostname 2>/dev/null || true)"
    if [[ "${#name}" -lt 2 || "$name" == 'localhost' ]] || ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        skip "this machine has no usable host name"
    fi
    assert_eq 'Linux <host> 6.8' "$(mask "Linux $name 6.8")"
    assert_eq 'alice@<host>:~$' "$(mask "alice@$name:~\$")"
    assert_eq '<host>' "$(mask "$name")"
    # Upper case is found as well.
    assert_eq 'on <host>.' "$(mask "on ${name^^}.")"
    # A longer word that merely contains the name stays.
    assert_eq "x${name}y" "$(mask "x${name}y")"
}

test_extra_names_are_replaced() {
    IMPACT_MASK_NAMES=(fileserver.example.org pc-042)
    assert_eq 'copy to <host>:/data' "$(mask 'copy to fileserver.example.org:/data')"
    assert_eq 'from <host> (<address>)' "$(mask 'from pc-042 (192.0.2.7)')"
    assert_eq 'pc-0421 stays' "$(mask 'pc-0421 stays')"
    # A name with characters that are special in patterns is taken as text.
    IMPACT_MASK_NAMES=('a.b')
    assert_eq 'axb and <host>' "$(mask 'axb and a.b')"
    # Unusable names are ignored and cannot break the filter.
    IMPACT_MASK_NAMES=('x' 'bad name' 's/x/y/' '')
    assert_eq 'bad name s/x/y/ x' "$(mask 'bad name s/x/y/ x')"
}

test_many_lines_and_empty_input() {
    local output
    output="$(printf 'one 192.0.2.1\n\ntwo 192.0.2.2\n' | impact_mask_text)"
    assert_eq $'one <address>\n\ntwo <address>' "$output"
    assert_eq '' "$(printf '' | impact_mask_text)"
}
