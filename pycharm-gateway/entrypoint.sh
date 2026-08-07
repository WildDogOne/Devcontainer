#!/bin/sh
# Container entrypoint. Runs as root on every start/restart - this is what
# ../.devcontainer/devcontainer.json's postStartCommand did for the Dev Containers setup,
# but there's no devcontainer.json lifecycle here, so the image's own ENTRYPOINT has to
# do it directly. sshd handles the per-connection privilege drop to dev via key auth
# (AllowUsers in sshd_config) - this script never becomes that user itself.
set -eu

# Seeds dev's authorized_keys from whatever pubkey(s) docker-compose.yml bind-mounted
# read-only at /run/host-authorized-keys. Copied rather than bind-mounted directly as
# authorized_keys itself, because sshd's StrictModes rejects a file with the host's own
# ownership/permissions.
mkdir -p /home/dev/.ssh
if [ -d /run/host-authorized-keys ]; then
  cat /run/host-authorized-keys/*.pub > /home/dev/.ssh/authorized_keys 2>/dev/null || true
fi
chown -R dev:dev /home/dev/.ssh
chmod 700 /home/dev/.ssh
[ -f /home/dev/.ssh/authorized_keys ] && chmod 600 /home/dev/.ssh/authorized_keys

# Egress allowlist proxy first, so dockerd's own image pulls go through it too. /etc/
# environment (see Dockerfile) covers SSH login sessions via PAM but not this script's
# own process tree, hence the explicit export here for dockerd's benefit.
export HTTP_PROXY=http://127.0.0.1:3128
export HTTPS_PROXY=http://127.0.0.1:3128
export NO_PROXY=localhost,127.0.0.1
nohup squid -f /etc/squid/squid.conf -N > /tmp/squid.log 2>&1 &
sleep 1
nohup dockerd --host=unix:///var/run/docker.sock > /tmp/dockerd.log 2>&1 &
sleep 1

# Forwards the host's ssh-agent for git SSH auth and seeds known_hosts - unrelated to
# Gateway's own inbound SSH connection above (see ssh-agent-setup.sh). Runs as dev
# since it writes under ~/.ssh and uses dev's passwordless sudo for the /etc/zsh write.
su dev -c /usr/local/bin/ssh-agent-setup.sh

exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
