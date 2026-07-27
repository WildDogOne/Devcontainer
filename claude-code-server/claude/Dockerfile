FROM python:3.12-alpine

RUN apk add --no-cache \
    nodejs \
    npm \
    docker-cli \
    docker-cli-compose \
    github-cli \
    ripgrep \
    jq \
    fzf \
    zsh \
    git \
    openssh-client \
    curl \
    bash \
    sudo \
    shadow \
    libstdc++ \
    # unzip: required by the Bun install script to extract its release archive
    unzip \
    # gcompat: Claude Code's own binary/tooling can pull in glibc-built pieces
    # that fail under musl without this compatibility shim.
    gcompat

ARG USERNAME=claude
ARG USER_UID=1000
ARG USER_GID=$USER_UID
# GID of the *host's* /var/run/docker.sock group, so this user can talk to the
# host's Docker daemon without sudo. Find it with: stat -c '%g' /var/run/docker.sock
ARG DOCKER_GID=999

RUN addgroup -g $USER_GID $USERNAME \
    && adduser -D -u $USER_UID -G $USERNAME -s /bin/zsh $USERNAME \
    && EXISTING_GROUP="$(getent group $DOCKER_GID | cut -d: -f1)" \
    && if [ -z "$EXISTING_GROUP" ]; then addgroup -g $DOCKER_GID docker; EXISTING_GROUP=docker; fi \
    && addgroup $USERNAME "$EXISTING_GROUP" \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

RUN npm install -g @anthropic-ai/claude-code

USER $USERNAME

# Bun is required by the Telegram plugin
ENV BUN_INSTALL="/home/${USERNAME}/.bun"
ENV PATH="$BUN_INSTALL/bin:$PATH"
RUN curl -fsSL https://bun.sh/install | bash

WORKDIR /workspace

CMD ["sleep", "infinity"]
