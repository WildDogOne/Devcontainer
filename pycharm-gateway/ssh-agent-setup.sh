#!/bin/sh
# Wires up SSH public-key auth for git inside the container by forwarding the
# *host's* ssh-agent rather than copying private keys into the image/container.
# Run from entrypoint.sh on every container start (see docker-compose.yml).
#
# docker-compose.yml binds two candidate agent sockets, since this project runs
# on both a Mac (Docker Desktop) and an Arch Linux box, and the right one
# depends on which host actually ran `docker`:
#   - /run/host-services/ssh-auth.sock: Docker Desktop's own always-on
#     forwarded agent socket (macOS/Windows). Fixed path, independent of
#     whatever environment launched the container - works even if PyCharm was
#     opened from the Dock with no SSH_AUTH_SOCK in its process env.
#   - /tmp/host-ssh-agent.sock: a direct bind-mount of the launching process's
#     $SSH_AUTH_SOCK, for a native Linux Docker host with a running ssh-agent.
# Only one of these will ever be a real socket on a given host; the other
# mount is a harmless empty directory (Docker auto-creates missing bind-mount
# sources) or a bind of /dev/null when SSH_AUTH_SOCK was unset on the host.
set -eu

SOCK=""
if [ -S /run/host-services/ssh-auth.sock ]; then
  SOCK=/run/host-services/ssh-auth.sock
elif [ -S /tmp/host-ssh-agent.sock ]; then
  SOCK=/tmp/host-ssh-agent.sock
fi

# /etc/zsh/zshenv.local is sourced by every zsh invocation (login or not,
# interactive or not) via the include hook added in Dockerfile - unlike
# /etc/profile.d, which plain zsh doesn't read on its own.
if [ -n "$SOCK" ]; then
  # Docker Desktop's forwarded socket comes in root:root 0660 - unreachable by
  # the non-root dev user. dev already has passwordless root (needed
  # for the Docker-in-Docker setup in entrypoint.sh), so this doesn't lower
  # the container's actual security posture, just makes explicit access it
  # already effectively had.
  sudo chmod 666 "$SOCK"
  echo "export SSH_AUTH_SOCK=$SOCK" | sudo tee /etc/zsh/zshenv.local >/dev/null
else
  sudo rm -f /etc/zsh/zshenv.local
  echo "ssh-agent-setup: no forwarded SSH agent socket found - git SSH auth won't work this session." >&2
fi

# Seed known_hosts for the common git remotes so the first SSH connection
# doesn't hit an interactive host-key prompt (which would just hang under
# entrypoint.sh / non-interactive git operations).
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/known_hosts
for host in github.com gitlab.com bitbucket.org; do
  if ! grep -q "^$host " ~/.ssh/known_hosts 2>/dev/null; then
    ssh-keyscan -H "$host" >> ~/.ssh/known_hosts 2>/dev/null || true
  fi
done
