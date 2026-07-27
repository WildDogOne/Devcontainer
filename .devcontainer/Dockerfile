FROM python:3.12-alpine

# Note: the official devcontainer "features" (node, github-cli, docker-in-docker,
# common-utils) all assume apt/Debian, so on Alpine everything is installed by hand below.
RUN apk add --no-cache \
    nodejs \
    npm \
    docker \
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
    # gcompat: Claude Code's bundled ripgrep binary is built against glibc and
    # fails to run under musl without this compatibility shim.
    gcompat

# Create a non-root "vscode" user (Alpine base images don't ship one), matching
# UID/GID 1000 so files created in the container stay writable on the host.
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID
RUN addgroup -g $USER_GID $USERNAME \
    && adduser -D -u $USER_UID -G $USERNAME -s /bin/zsh $USERNAME \
    && addgroup $USERNAME docker \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

RUN npm install -g @anthropic-ai/claude-code

USER $USERNAME
WORKDIR /home/$USERNAME
