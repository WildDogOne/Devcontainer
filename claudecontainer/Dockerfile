FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# Mirrors ../.devcontainer/Dockerfile's package list (same reasoning: hand-installed
# rather than devcontainer.json "features", since there's no devcontainer.json here at
# all; NodeSource for a current Node, since Ubuntu 24.04's own "nodejs" is 18.x/EOL and
# below Claude Code's >=22 requirement; "gh" isn't in Ubuntu's default repos).
# openssh-client (not -server): outbound git-over-SSH only - see entrypoint.sh/run.sh
# for host ssh-agent forwarding. Nothing listens for inbound SSH in this image.
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

# Ubuntu 24.04's own python3 is 3.12; 3.14 comes from the deadsnakes PPA (needs
# software-properties-common's add-apt-repository - there's no plain apt source line
# that's stable across releases). update-alternatives repoints the system
# /usr/bin/python3 and adds /usr/bin/python at 3.14, so a project's .venv (created with
# either binary, on whatever host actually runs `docker build`) resolves the same way
# inside this container. Trade-off: apt's own python3-apt module stays compiled
# against 3.12, so python3-dependent apt tooling (add-apt-repository, unattended-upgrade)
# would break if invoked again after this point - not used anywhere else in this image
# or its runtime scripts, so left as-is rather than avoided.
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
    python3.14 \
    python3.14-venv \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.14 1 \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.14 1 \
    && rm -rf /var/lib/apt/lists/*

# Sourced by every zsh invocation (login or not, interactive or not), unlike
# /etc/profile.d which plain zsh doesn't read - so this applies the same whether you
# land here via `docker exec` or the entrypoint's own login shell. Walks up from $PWD
# rather than a fixed path, since this image doesn't know in advance which project
# directory a given session will open (see run.sh's cwd mount).
RUN mkdir -p /etc/zsh && cat <<'EOF' > /etc/zsh/zshenv.venv
_venv_dir=$PWD
while [ -n "$_venv_dir" ] && [ "$_venv_dir" != "/" ]; do
  if [ -f "$_venv_dir/.venv/bin/activate" ]; then
    . "$_venv_dir/.venv/bin/activate"
    break
  fi
  _venv_dir=${_venv_dir%/*}
done
unset _venv_dir
EOF
RUN echo '[ -f /etc/zsh/zshenv.venv ] && . /etc/zsh/zshenv.venv' >> /etc/zsh/zshenv

# Belt-and-suspenders alongside entrypoint.sh's explicit --preserve-env: covers any
# other login/PAM-aware program that reads /etc/environment directly (sudo's own PAM
# session module included, depending on /etc/pam.d/sudo config).
RUN cat <<'EOF' >> /etc/environment
HTTP_PROXY=http://127.0.0.1:3128
HTTPS_PROXY=http://127.0.0.1:3128
NO_PROXY=localhost,127.0.0.1
EOF

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x  /usr/local/bin/entrypoint.sh

# Create a non-root "dev" user matching UID/GID 1000 so files created in the
# container stay writable on the host. docker.io's postinst already creates the
# "docker" group. Ubuntu's base image already ships a default "ubuntu" user/group
# at 1000:1000, so it has to go first to free up that UID/GID.
ARG USERNAME=dev
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

# Stays root: entrypoint.sh needs it to start dockerd/squid, then drops to dev itself
# (via `sudo -u dev`) before running the actual command.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
