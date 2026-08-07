#!/bin/sh
# Container entrypoint. Runs as root (needed to start dockerd/squid below), then drops
# to dev and execs the command docker run was given (default: an interactive `claude`
# session) - no persistent daemon, no listening port; the container exits when that
# command does. Meant to be started fresh per session via run.sh, not left running.
set -eu

# Egress allowlist proxy first, so dockerd's own image pulls go through it too. /etc/
# environment (see Dockerfile) covers the `su -l` session below via PAM but not this
# script's own process tree, hence the explicit export here for dockerd's benefit.
export HTTP_PROXY=http://127.0.0.1:3128
export HTTPS_PROXY=http://127.0.0.1:3128
export NO_PROXY=localhost,127.0.0.1
nohup squid -f /etc/squid/squid.conf -N > /tmp/squid.log 2>&1 &
sleep 1
nohup dockerd --host=unix:///var/run/docker.sock > /tmp/dockerd.log 2>&1 &
sleep 1

if [ "$#" -eq 0 ]; then
  set -- zsh -lc claude
fi

# `-l` gives dev a real login session (HOME, PATH, PAM's /etc/environment) before the
# -c script's `cd "$0"` overrides the cwd back to whatever run.sh mounted - login's own
# `cd ~dev` would otherwise land the command in dev's home instead of the project dir.
exec su -l -s /bin/sh -c 'cd "$0" || exit 1; exec "$@"' dev "$PWD" "$@"
