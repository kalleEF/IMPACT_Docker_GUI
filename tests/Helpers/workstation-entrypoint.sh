#!/bin/bash
# Entrypoint for the Workstation test container.
# Fixes Docker socket group permissions so testuser can use Docker CLI,
# then starts SSHD in the foreground.

DOCKER_SOCK=/var/run/docker.sock

if [ -S "$DOCKER_SOCK" ]; then
    # Get the GID of the mounted Docker socket
    SOCK_GID=$(stat -c '%g' "$DOCKER_SOCK")

    # If the socket GID differs from the docker group, update the group
    CURRENT_GID=$(getent group docker | cut -d: -f3)
    if [ "$SOCK_GID" != "$CURRENT_GID" ]; then
        groupmod -g "$SOCK_GID" docker 2>/dev/null || true
    fi

    # Ensure testuser is in the docker group
    usermod -aG docker testuser 2>/dev/null || true
fi

exec /usr/sbin/sshd -D -e
