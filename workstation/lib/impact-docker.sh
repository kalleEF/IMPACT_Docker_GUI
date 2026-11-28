#!/bin/bash
# =============================================================================
# impact-docker.sh: read-only questions to Docker
#
# Purpose
#   Docker has two parts: the program "docker" that people type, and the
#   "daemon" (dockerd), a service that runs in the background and does the
#   work. The functions here answer: is Docker installed and from which
#   source, which version, does the daemon answer, does it start with the
#   machine. impact_docker_ro runs a docker command after checking that it
#   is one that only reads.
#
# Who runs it
#   Nobody directly. impact-common.sh loads it.
#
# Usage (inside a command, after loading impact-common.sh)
#   if impact_docker_daemon_reachable; then
#       impact_docker_ro ps --format '{{.Names}}'
#   fi
#   version="$(impact_docker_engine_version)" && impact_version_ge "$version" 28.3.3
#
# What it changes on the system
#   Nothing. Every function here only reads.
#
# How to undo
#   Nothing to undo.
# =============================================================================

# -----------------------------------------------------------------------------
# Reading help: bash constructs that appear in this file
#   NAME=text            store a text in the variable NAME; "$NAME" reads it
#   local NAME           a variable that exists only inside one function
#   "$1" "$2" "$@" "$#"  first parameter, second parameter, all parameters,
#                        number of parameters
#   "${NAME:-text}"      the value of NAME, or "text" when NAME is unset or empty
#   $( command )         the text that the command prints
#   [[ ... ]]            a test: -f plain file, -d folder, -L symbolic link,
#                        -e exists, -r readable, -x executable, -z empty text,
#                        -n text with content, == equal, != different,
#                        =~ matches a pattern
#   (( ... ))            arithmetic: true when the result is not zero
#   A && B               run B only when A succeeded
#   A || B               run B only when A failed
#   ! command            true when the command fails
#   if / case / for / while   branches and loops; "case" compares one value
#                        with several patterns
#   >file >>file <file   write to a file (replace it / add to its end), read
#                        from a file
#   2>/dev/null  >&2     throw error messages away / write to the error channel
#   command1 | command2  hand the output of command1 to command2
#   return N / exit N    end the function / the script with status N; 0 means
#                        success
#   list=(a b)  "${list[@]}"  "${#list[@]}"   a list, all its entries, their number
#   command || true      accept a failure of this command ("set -e" would
#                        otherwise stop the script there)
# Constructs beyond these are explained where they are first used.
# -----------------------------------------------------------------------------

# The oldest Docker Engine version that keeps ports published on 127.0.0.1
# closed to neighbouring computers. ACCESS_MODE=tunnel needs it.
# shellcheck disable=SC2034
# Reason for SC2034 (variable appears unused): commands read this value.
readonly IMPACT_DOCKER_MIN_VERSION='28.3.3'

# impact_docker_installed
#   Result: success when the program "docker" is found in the fixed PATH.
impact_docker_installed() {
    impact_have_tool docker
}

# impact_docker_install_source
#   Prints where the Docker on this machine comes from:
#     docker-ce   the package of Docker's own apt source (the supported way)
#     snap        the snap package (not supported: it cannot reach all
#                 folders of the machine)
#     docker.io   the package of Ubuntu
#     other       a docker program of unknown origin
#     none        no docker program
#   Read-only.
impact_docker_install_source() {
    local program='' real=''
    if impact_have_tool docker; then
        program="$(command -v docker)"
        real="$(readlink -f -- "$program" 2>/dev/null)" || real="$program"
    fi
    if [[ "$real" == /snap/* || "$real" == /var/lib/snapd/* ]]; then
        printf 'snap\n'
        return 0
    fi
    if [[ -z "$program" ]]; then
        if [[ -e /snap/bin/docker ]]; then
            printf 'snap\n'
        else
            printf 'none\n'
        fi
        return 0
    fi
    # dpkg-query asks the package database. The format prints "installed"
    # for a package that is fully installed.
    if [[ "$(dpkg-query -W -f='${db:Status-Status}' docker-ce 2>/dev/null)" == 'installed' ]]; then
        printf 'docker-ce\n'
    elif [[ "$(dpkg-query -W -f='${db:Status-Status}' docker.io 2>/dev/null)" == 'installed' ]]; then
        printf 'docker.io\n'
    else
        printf 'other\n'
    fi
}

# impact_docker_snap_present
#   Result: success when the snap package of Docker is installed, also next
#   to another Docker.
impact_docker_snap_present() {
    [[ -e /snap/bin/docker || -d /snap/docker ]]
}

# impact_docker_engine_version
#   Prints the version of the installed Docker Engine, for example 29.1.0.
#   It asks the daemon program itself ("dockerd --version"), which works
#   whether the daemon runs or not.
#   Result: failure when dockerd is missing or prints no version.
impact_docker_engine_version() {
    local output
    impact_have_tool dockerd || return 1
    output="$(timeout 20 dockerd --version 2>/dev/null)" || return 1
    # The output looks like: Docker version 29.1.0, build 1234abc
    if [[ "$output" =~ [Vv]ersion[[:space:]]+([0-9]+(\.[0-9]+)+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# impact_docker_server_version
#   Prints the version of the running Docker daemon.
#   Result: failure when the daemon does not answer within 20 seconds.
impact_docker_server_version() {
    local output
    impact_have_tool docker || return 1
    output="$(timeout 20 docker version --format '{{.Server.Version}}' 2>/dev/null)" || return 1
    if [[ "$output" =~ ^([0-9]+(\.[0-9]+)+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# impact_docker_daemon_reachable
#   Result: success when the Docker daemon of this machine answers.
#   Example: if ! impact_docker_daemon_reachable; then impact_warn "Docker does not answer."; fi
impact_docker_daemon_reachable() {
    impact_docker_server_version >/dev/null
}

# impact_docker_boot_state
#   Prints whether Docker starts with the machine:
#     enabled    the service docker.service is enabled
#     socket     only docker.socket is enabled: Docker starts at its first
#                use, so containers do not come back by themselves after a
#                reboot
#     disabled   neither is enabled
#     unknown    systemd does not run here, so the question has no answer
#   Read-only.
impact_docker_boot_state() {
    local state
    if [[ ! -d /run/systemd/system ]] || ! impact_have_tool systemctl; then
        printf 'unknown\n'
        return 0
    fi
    state="$(systemctl is-enabled docker.service 2>/dev/null)" || true
    if [[ "$state" == 'enabled' || "$state" == 'enabled-runtime' ]]; then
        printf 'enabled\n'
        return 0
    fi
    state="$(systemctl is-enabled docker.socket 2>/dev/null)" || true
    if [[ "$state" == 'enabled' || "$state" == 'enabled-runtime' ]]; then
        printf 'socket\n'
        return 0
    fi
    printf 'disabled\n'
}

# impact_docker_ro SUBCOMMAND [ARGUMENTS...]
#   Runs a docker command that only reads, with a time limit of 60 seconds.
#   Accepted: ps, images, inspect, version, info, port, top, logs, diff,
#   history, and the two-word forms "image ls|inspect|history",
#   "container ls|inspect|port|top|logs|diff", "volume ls|inspect",
#   "network ls|inspect", "system df|info". Anything else is refused, so a
#   command that should only look can never change Docker by mistake.
#   Result: the exit code of docker; 2 for a refused subcommand; 124 when
#   the time limit was reached.
#   Example: impact_docker_ro ps --all --filter label=impact.account=alice --format '{{.Names}}'
impact_docker_ro() {
    local first="${1:-}" second="${2:-}" allowed=0
    case "$first" in
        ps | images | inspect | version | info | port | top | logs | diff | history)
            allowed=1
            ;;
        image)
            if [[ "$second" == 'ls' || "$second" == 'inspect' || "$second" == 'history' ]]; then
                allowed=1
            fi
            ;;
        container)
            case "$second" in
                ls | inspect | port | top | logs | diff) allowed=1 ;;
                *) ;;
            esac
            ;;
        volume | network)
            if [[ "$second" == 'ls' || "$second" == 'inspect' ]]; then
                allowed=1
            fi
            ;;
        system)
            if [[ "$second" == 'df' || "$second" == 'info' ]]; then
                allowed=1
            fi
            ;;
        *) ;;
    esac
    if ((allowed == 0)); then
        impact_error "impact_docker_ro refuses 'docker $(impact_display "$first $second")': it is not on the list of read-only commands."
        return 2
    fi
    timeout 60 docker "$@"
}
