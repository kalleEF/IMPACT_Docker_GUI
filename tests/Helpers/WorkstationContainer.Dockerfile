# Simulated remote Linux workstation for E2E testing.
# Extends SshdContainer with the Docker CLI so that the test suite can
# orchestrate Docker builds via SSH — Docker-out-of-Docker (DooD) pattern.
#
# The container does NOT run its own Docker daemon; instead, the host's
# Docker socket is mounted at runtime:
#   docker run -d -p 2222:22 -v /var/run/docker.sock:/var/run/docker.sock \
#              --name workstation-test impact-workstation-test
#
# Build:   docker build -t impact-workstation-test -f tests/Helpers/WorkstationContainer.Dockerfile .
# Run:     docker run -d -p 2222:22 -v /var/run/docker.sock:/var/run/docker.sock --name workstation-test impact-workstation-test

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# ── Install OS packages ─────────────────────────────────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-server \
        git \
        ca-certificates \
        curl \
        gnupg \
        lsb-release && \
    rm -rf /var/lib/apt/lists/*

# ── Install Docker CLI only (no daemon — we use the host's via socket) ──────
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# ── Create sshd run directory and host keys ──────────────────────────────────
RUN mkdir -p /run/sshd && \
    ssh-keygen -A

# ── Create test user with Docker group access ───────────────────────────────
#    The docker group may not exist yet — create with a fixed GID that matches
#    what most Docker socket permissions use, then add testuser.
RUN groupadd -g 999 docker 2>/dev/null || true && \
    useradd -m -s /bin/bash testuser && \
    usermod -aG docker testuser && \
    mkdir -p /home/testuser/.ssh && \
    chmod 700 /home/testuser/.ssh && \
    chown -R testuser:testuser /home/testuser/.ssh

# ── Fake repository structure (mirrors real workstation layout) ──────────────
RUN mkdir -p /home/testuser/Schreibtisch/Repositories/IMPACTncd_Germany/docker_setup && \
    mkdir -p /home/testuser/Schreibtisch/Repositories/IMPACTncd_Germany/inputs && \
    # Production-like storage mount paths
    mkdir -p /mnt/Storage_1/IMPACT_Storage/Base/outputs && \
    mkdir -p /mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop && \
    # sim_design.yaml with absolute POSIX paths
    echo "output_dir: /mnt/Storage_1/IMPACT_Storage/Base/outputs" \
        > /home/testuser/Schreibtisch/Repositories/IMPACTncd_Germany/inputs/sim_design.yaml && \
    echo "synthpop_dir: /mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop" \
        >> /home/testuser/Schreibtisch/Repositories/IMPACTncd_Germany/inputs/sim_design.yaml && \
    chown -R testuser:testuser /home/testuser/Schreibtisch && \
    chown -R testuser:testuser /mnt/Storage_1

# ── Initialize fake git repo ────────────────────────────────────────────────
RUN git config --global --add safe.directory '*' && \
    cd /home/testuser/Schreibtisch/Repositories/IMPACTncd_Germany && \
    git init && \
    git config user.email "test@test.com" && \
    git config user.name "Test User" && \
    echo "# Test" > README.md && \
    git add -A && \
    git commit -m "init" && \
    chown -R testuser:testuser .

# ── SSHD config: key-only auth ──────────────────────────────────────────────
RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    echo "StrictModes no" >> /etc/ssh/sshd_config

# ── Entrypoint: fix docker socket permissions, then start sshd ──────────────
#    When the host socket is mounted, its GID may differ from 999.
#    We detect the actual GID and adjust the docker group to match.
#    NOTE: Inlined instead of COPY to avoid Docker build context path issues
#    on Windows (paths with spaces / OneDrive paths cause empty context).
RUN printf '#!/bin/bash\n\
DOCKER_SOCK=/var/run/docker.sock\n\
if [ -S "$DOCKER_SOCK" ]; then\n\
    SOCK_GID=$(stat -c "%%g" "$DOCKER_SOCK")\n\
    DOCKER_GID=$(getent group docker | cut -d: -f3)\n\
    if [ "$SOCK_GID" != "$DOCKER_GID" ]; then\n\
        if [ "$SOCK_GID" = "0" ]; then\n\
            chgrp docker "$DOCKER_SOCK" 2>/dev/null || true\n\
        else\n\
            groupmod -g "$SOCK_GID" docker 2>/dev/null || true\n\
        fi\n\
    fi\n\
    chmod g+rw "$DOCKER_SOCK" 2>/dev/null || true\n\
    usermod -aG docker testuser 2>/dev/null || true\n\
fi\n\
exec /usr/sbin/sshd -D -e\n' > /entrypoint.sh && \
    chmod +x /entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
