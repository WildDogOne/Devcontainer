FROM ubuntu:24.04

# Ubuntu (glibc), not Alpine: JetBrains' Remote Development backend (the JVM PyCharm
# runs inside the dev container) is a glibc binary and cannot start under Alpine's musl
# libc - confirmed, still-open JetBrains bugs JBR-7349 and IJPL-170288. See README.md
# "Base image" section for details.
ARG DEBIAN_FRONTEND=noninteractive

# Everything below is installed by hand rather than via devcontainer.json "features"
# for parity with the rest of this setup (squid, manual docker-in-docker, proxy env) -
# not because the official features wouldn't work here, unlike on the old Alpine base.
# Ubuntu 24.04's own "nodejs" package is 18.x (EOL, and below Claude Code's own
# node >=22 requirement), so Node comes from NodeSource's 22.x LTS repo instead;
# same story for "gh", which isn't in Ubuntu's default repos at all.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && chmod go+r /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    nodejs \
    docker.io \
    docker-compose-v2 \
    gh \
    ripgrep \
    jq \
    fzf \
    zsh \
    git \
    openssh-client \
    bash \
    sudo \
    # squid: loopback-only egress allowlist proxy, see squid.conf.
    squid \
    && rm -rf /var/lib/apt/lists/*

COPY squid.conf /etc/squid/squid.conf
COPY allowed-domains.txt /etc/squid/allowed-domains.txt

# Create a non-root "vscode" user matching UID/GID 1000 so files created in the
# container stay writable on the host. docker.io's postinst already creates the
# "docker" group. Ubuntu's base image already ships a default "ubuntu" user/group
# at 1000:1000, so it has to go first to free up that UID/GID.
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID
RUN if getent passwd ubuntu >/dev/null; then userdel -r ubuntu; fi \
    && if getent group ubuntu >/dev/null; then groupdel ubuntu; fi \
    && groupadd -g $USER_GID $USERNAME \
    && useradd -m -u $USER_UID -g $USER_GID -s /bin/zsh $USERNAME \
    && usermod -aG docker $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

RUN npm install -g @anthropic-ai/claude-code

USER $USERNAME
WORKDIR /home/$USERNAME
