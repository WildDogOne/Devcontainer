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

# sudo (not `su -l`): su's login-session setup cd's to the target user's home as part
# of establishing the session, and that happens before a `-c` script gets a chance to
# `cd` back - landed every session in /home/dev regardless of run.sh's mount. sudo
# never chdir's on its own, so the cwd docker run -w set (run.sh's project mount)
# just passes through untouched; -H still sets HOME=/home/dev for dev's own configs.
exec sudo -u dev -H --preserve-env=HTTP_PROXY,HTTPS_PROXY,NO_PROXY -- "$@"
