# Minimal SSHD container for CI integration testing.
# Provides an SSH target that the test suite can connect to, simulating a remote workstation.
#
# Build:   docker build -t impact-sshd-test -f tests/Helpers/SshdContainer.Dockerfile .
# Run:     docker run -d -p 2222:22 --name sshd-test impact-sshd-test
# Connect: ssh -p 2222 -i <key> testuser@localhost

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-server \
        git \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Create sshd run directory and generate host keys
RUN mkdir -p /run/sshd && \
    ssh-keygen -A

# Create test user (matches the RemoteUser used in tests)
RUN useradd -m -s /bin/bash testuser && \
    mkdir -p /home/testuser/.ssh && \
    chmod 700 /home/testuser/.ssh && \
    chown -R testuser:testuser /home/testuser/.ssh

# Create a fake repository structure for remote tests
RUN mkdir -p /home/testuser/Schreibtisch/Repositories/IMPACTncd_Germany/docker_setup && \
    mkdir -p /home/testuser/Schreibtisch/Repositories/IMPACTncd_Germany/inputs && \
    # Create the actual storage mount paths used in production sim_design.yaml
    mkdir -p /mnt/Storage_1/IMPACT_Storage/Base/outputs && \
    mkdir -p /mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop && \
    # sim_design.yaml uses absolute paths pointing to the /mnt storage mount
    echo "output_dir: /mnt/Storage_1/IMPACT_Storage/Base/outputs" > /home/testuser/Schreibtisch/Repositories/IMPACTncd_Germany/inputs/sim_design.yaml && \
    echo "synthpop_dir: /mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop" >> /home/testuser/Schreibtisch/Repositories/IMPACTncd_Germany/inputs/sim_design.yaml && \
    chown -R testuser:testuser /home/testuser/Schreibtisch && \
    chown -R testuser:testuser /mnt/Storage_1

# Initialize the fake repo as a git repository so git commands work
# safe.directory needed because the dir is owned by testuser but we run as root
RUN git config --global --add safe.directory '*' && \
    cd /home/testuser/Schreibtisch/Repositories/IMPACTncd_Germany && \
    git init && \
    git config user.email "test@test.com" && \
    git config user.name "Test User" && \
    echo "# Test" > README.md && \
    git add -A && \
    git commit -m "init" && \
    chown -R testuser:testuser .

# Configure SSHD for key-only auth (no password)
RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    echo "StrictModes no" >> /etc/ssh/sshd_config

# The test runner must mount/copy the public key into /home/testuser/.ssh/authorized_keys
# before connecting. See the CI workflow for how this is done.

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D", "-e"]
